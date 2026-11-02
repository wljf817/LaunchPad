#!/usr/bin/env python3
"""Record how the reference VM's text input service (com.apple.dock.ecti) handles key equivalents.

Frida cannot reach the service: frida-server cannot inject in the reference VM and the XPC service
does not inherit DYLD_INSERT_LIBRARIES from the GUI session. LLDB can attach (SIP is off).

Usage (in the reference VM, with the Command Line Tools' Python and LLDB):
    sudo PYTHONPATH="$(lldb -P)" /usr/bin/python3 lldb-ecti-menu.py <pid> <seconds> <out.jsonl> [nomenu] [events]

Attaches to <pid>, writes the text field's value and the main menu tree, then lets the process run
for <seconds> with breakpoints on -[NSMenu performKeyEquivalent:], -[NSApplication
sendAction:to:from:] and -[NSApplication terminate:]; at each stop it logs the arguments and
continues. At the end it stops the process, writes both again and detaches. One JSON object per
line, each with t = seconds since the attach (with "nomenu" the menu trees are left out; with
"events" -[NSApplication sendEvent:] also stops, and key events are logged):
    field     reason ("attach" or "end"); the text field's string value
    menu      reason ("attach" or "end"); the tree: per menu its title and items, per item title,
              key equivalent, modifier mask, action, target class, tag, separator, enabled, hidden,
              alternate and submenu
    kequiv    the menu whose performKeyEquivalent: runs, the event's charactersIgnoringModifiers and
              modifier flags
    action    the action, the target's class, the sender's class and title
    event     (with "events") a key down or up reaching -[NSApplication sendEvent:]: its
              charactersIgnoringModifiers and modifier flags
    terminate the sender's class
    exit      the process exited while attached
"""
import json
import sys
import time

import lldb

pid, seconds, out_path = int(sys.argv[1]), float(sys.argv[2]), sys.argv[3]
options = set(sys.argv[4:])
with_menu = "nomenu" not in options
with_events = "events" in options
start = time.monotonic()
out = open(out_path, "w")


def write(obj):
    obj["t"] = round(time.monotonic() - start, 4)
    out.write(json.dumps(obj, ensure_ascii=False) + "\n")
    out.flush()


debugger = lldb.SBDebugger.Create()
debugger.SetAsync(False)
target = debugger.CreateTarget("")
error = lldb.SBError()
listener = debugger.GetListener()
process = target.AttachToProcessWithID(listener, pid, error)
if not error.Success():
    sys.exit(f"attach failed: {error}")

# Without debug info every message send needs a cast to its return type; the variadic
# +stringWithFormat: goes through a variadic cast of objc_msgSend.
ITEM = ('((id (*)(id, SEL, id, ...))objc_msgSend)((id)objc_getClass("NSString"), @selector(stringWithFormat:), @"%@\\x1f%@\\x1f%lu\\x1f%s\\x1f%s\\x1f%ld\\x1f%d\\x1f%d\\x1f%d\\x1f%d\\x1f%d", '
        '(id)[(id){i} title], (id)[(id){i} keyEquivalent], (unsigned long)[(id){i} keyEquivalentModifierMask], '
        '(const char *)((SEL)[(id){i} action] ? (const char *)sel_getName((SEL)[(id){i} action]) : ""), '
        '(const char *)((id)[(id){i} target] ? (const char *)object_getClassName((id)[(id){i} target]) : ""), '
        '(long)[(id){i} tag], (int)(BOOL)[(id){i} isSeparatorItem], (int)(BOOL)[(id){i} isEnabled], '
        '(int)(BOOL)[(id){i} isHidden], (int)(BOOL)[(id){i} isAlternate], (int)((id)[(id){i} submenu] != nil))')


def evaluate(frame, expr):
    options = lldb.SBExpressionOptions()
    options.SetLanguage(lldb.eLanguageTypeObjC)
    options.SetTimeoutInMicroSeconds(5_000_000)
    value = frame.EvaluateExpression(expr, options)
    if value.GetError().Fail():
        raise RuntimeError(f"{expr}: {value.GetError()}")
    return value


def cstring(frame, expr):
    address = evaluate(frame, expr).GetValueAsUnsigned()
    if address == 0:
        return None
    error = lldb.SBError()
    raw = process.ReadCStringFromMemory(address, 1 << 16, error)
    if not error.Success():
        raise RuntimeError(f"{expr}: {error}")
    return raw


def nsstring(frame, expr):
    return cstring(frame, f"(const char *)[(id)({expr}) UTF8String]")


def menu_tree(frame, menu):
    count = evaluate(frame, f"(long)[(id){menu} numberOfItems]").GetValueAsSigned()
    tree = {"title": nsstring(frame, f"(id)[(id){menu} title]"), "items": []}
    for index in range(count):
        item = evaluate(frame, f"(id)[(id){menu} itemAtIndex:{index}]").GetValueAsUnsigned()
        fields = nsstring(frame, ITEM.format(i=item)).split("\x1f")
        entry = {
            "title": fields[0], "key": fields[1], "mods": hex(int(fields[2])), "action": fields[3] or None,
            "target": fields[4] or None, "tag": int(fields[5]), "separator": fields[6] == "1",
            "enabled": fields[7] == "1", "hidden": fields[8] == "1", "alternate": fields[9] == "1",
            "submenu": None,
        }
        if fields[10] == "1":
            submenu = evaluate(frame, f"(id)[(id){item} submenu]").GetValueAsUnsigned()
            entry["submenu"] = menu_tree(frame, submenu)
        tree["items"].append(entry)
    return tree


def dump(reason):
    frame = process.GetSelectedThread().GetSelectedFrame()
    field = "(id)[(id)[(id)[NSApplication sharedApplication] delegate] textField]"
    write({"type": "field", "reason": reason, "stringValue": nsstring(frame, f"(id)[{field} stringValue]")})
    if with_menu:
        main = evaluate(frame, "(id)[(id)[NSApplication sharedApplication] mainMenu]").GetValueAsUnsigned()
        write({"type": "menu", "reason": reason, "menu": menu_tree(frame, main) if main else None})


def on_kequiv(frame):
    write({"type": "kequiv",
           "menu": nsstring(frame, "(id)[(id)$x0 title]"),
           "chars": nsstring(frame, "(id)[(id)$x2 charactersIgnoringModifiers]"),
           "flags": hex(evaluate(frame, "(unsigned long)[(id)$x2 modifierFlags]").GetValueAsUnsigned())})


def on_action(frame):
    sender_class = cstring(frame, "(const char *)object_getClassName((id)$x4)")
    title = None
    if sender_class and "MenuItem" in sender_class:
        title = nsstring(frame, "(id)[(id)$x4 title]")
    write({"type": "action",
           "action": cstring(frame, "(const char *)sel_getName((SEL)$x2)"),
           "target": cstring(frame, "(const char *)($x3 ? (const char *)object_getClassName((id)$x3) : \"nil\")"),
           "sender": sender_class, "senderTitle": title})


def on_send_event(frame):
    kind = evaluate(frame, "(unsigned long)[(id)$x2 type]").GetValueAsUnsigned()
    if kind in (10, 11):
        write({"type": "event", "event": "keyDown" if kind == 10 else "keyUp",
               "chars": nsstring(frame, "(id)[(id)$x2 charactersIgnoringModifiers]"),
               "flags": hex(evaluate(frame, "(unsigned long)[(id)$x2 modifierFlags]").GetValueAsUnsigned())})


def on_terminate(frame):
    write({"type": "terminate", "sender": cstring(frame, "(const char *)object_getClassName((id)$x2)")})


dump("attach")
handlers = {}
for symbol, handler in (("-[NSMenu performKeyEquivalent:]", on_kequiv),
                        ("-[NSApplication sendAction:to:from:]", on_action),
                        ("-[NSApplication terminate:]", on_terminate)):
    handlers[target.BreakpointCreateByName(symbol).GetID()] = handler
if with_events:
    handlers[target.BreakpointCreateByName("-[NSApplication sendEvent:]").GetID()] = on_send_event

# Run for the given time. At a breakpoint the loop logs it and continues; other stops are continued.
debugger.SetAsync(True)
process.Continue()
deadline = start + seconds
exited = False
event = lldb.SBEvent()
while time.monotonic() < deadline:
    if not listener.WaitForEvent(1, event) or not lldb.SBProcess.EventIsProcessEvent(event):
        continue
    state = lldb.SBProcess.GetStateFromEvent(event)
    if state in (lldb.eStateExited, lldb.eStateDetached, lldb.eStateCrashed):
        write({"type": "exit", "state": lldb.SBDebugger.StateAsCString(state),
               "status": process.GetExitStatus()})
        exited = True
        break
    if state == lldb.eStateStopped and not lldb.SBProcess.GetRestartedFromEvent(event):
        for thread in process:
            if thread.GetStopReason() == lldb.eStopReasonBreakpoint:
                handler = handlers.get(thread.GetStopReasonDataAtIndex(0))
                if handler is not None:
                    process.SetSelectedThread(thread)
                    handler(thread.GetFrameAtIndex(0))
        process.Continue()
if not exited:
    process.Stop()
    while listener.WaitForEvent(5, event):
        if lldb.SBProcess.EventIsProcessEvent(event) and lldb.SBProcess.GetStateFromEvent(event) == lldb.eStateStopped:
            break
    debugger.SetAsync(False)
    dump("end")
    process.Detach()
out.close()
