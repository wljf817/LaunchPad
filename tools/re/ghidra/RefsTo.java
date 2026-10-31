// Lists the functions that use given Objective-C selectors or strings, in a program that Ghidra has
// analyzed.
//
// Purpose: find who sends a message (its selector reference) or uses a notification name (a C string
// or the CFString built on it) in a stripped binary such as Dock, without decompiling it all.
//
// Usage (GHIDRA_INSTALL_DIR and JAVA_HOME exported), against a saved, analyzed project:
//   $GHIDRA_INSTALL_DIR/support/analyzeHeadless <project dir> <project name> \
//     -process <binary file name> -noanalysis -scriptPath tools/re/ghidra \
//     -postScript RefsTo.java <list file> <output file>
//
// The list file has one item per line: "sel:<selector>", "str:<exact string>" or
// "fn:<entry address in hex>". Lines that are empty or start with '#' are skipped.
//
// Output: one line per use, tab-separated: the item, the address of the instruction or data that
// uses it, and the containing function's entry point and name ("-" outside a function). A selector
// used through an objc_stub is reported at the stub's callers; a string used through data (a
// CFString constant) at that data's users.
// Keep the project, the lists and the output under research/ (clean room).

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Reference;

import java.io.PrintWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class RefsTo extends GhidraScript {
    @Override
    protected void run() throws Exception {
        String[] args = getScriptArgs();
        List<String> items = new ArrayList<>();
        for (String line : Files.readAllLines(Paths.get(args[0]), StandardCharsets.UTF_8)) {
            line = line.strip();
            if (!line.isEmpty() && !line.startsWith("#")) items.add(line);
        }
        Map<String, List<Address>> targets = new HashMap<>();
        for (String item : items) targets.put(item, new ArrayList<>());

        // Selector references: each 8-byte slot of __objc_selrefs points at the selector's name.
        MemoryBlock selrefs = currentProgram.getMemory().getBlock("__objc_selrefs");
        if (selrefs != null) {
            for (Address a = selrefs.getStart(); a.compareTo(selrefs.getEnd()) < 0; a = a.add(8)) {
                long value = currentProgram.getMemory().getLong(a) & 0x0000_7FFF_FFFF_FFFFL;
                String name = cString(toAddr(value));
                if (name != null && targets.containsKey("sel:" + name)) targets.get("sel:" + name).add(a);
            }
        }

        // Functions: "fn:<entry address>", reported at their callers.
        for (String item : items) {
            if (item.startsWith("fn:")) targets.get(item).add(toAddr(Long.parseUnsignedLong(item.substring(3).replace("0x", ""), 16)));
        }

        // Strings: the defined C string, and every pointer to it (CFString constants, tables).
        DataIterator data = currentProgram.getListing().getDefinedData(true);
        while (data.hasNext() && !monitor.isCancelled()) {
            Data d = data.next();
            Object value = d.getValue();
            if (!(value instanceof String)) continue;
            String key = "str:" + value;
            if (!targets.containsKey(key)) continue;
            targets.get(key).add(d.getAddress());
            for (Reference r : getReferencesTo(d.getAddress())) {
                if (getFunctionContaining(r.getFromAddress()) == null) targets.get(key).add(r.getFromAddress());
            }
        }

        try (PrintWriter out = new PrintWriter(Files.newBufferedWriter(Paths.get(args[1]), StandardCharsets.UTF_8))) {
            for (String item : items) {
                for (Address target : targets.get(item)) {
                    for (Reference r : getReferencesTo(target)) {
                        Address from = r.getFromAddress();
                        Function f = getFunctionContaining(from);
                        if (f != null && f.getName(true).startsWith("objc_stub::")) {
                            // A selector's message stub: its callers send the message.
                            for (Reference c : getReferencesTo(f.getEntryPoint())) printUse(out, item, c.getFromAddress());
                        } else if (f == null) {
                            // A pointer inside data, such as a CFString constant: the data's users.
                            Data d = getDataContaining(from);
                            Address start = d == null ? from : d.getAddress();
                            for (Reference c : getReferencesTo(start)) printUse(out, item, c.getFromAddress());
                        } else {
                            printUse(out, item, from);
                        }
                    }
                }
                if (targets.get(item).isEmpty()) out.println(item + "\tnot found");
            }
        }
    }

    private void printUse(PrintWriter out, String item, Address from) {
        Function f = getFunctionContaining(from);
        out.println(item + "\t" + from + "\t" + (f == null ? "-" : f.getEntryPoint() + "\t" + f.getName(true)));
    }

    private String cString(Address a) {
        try {
            StringBuilder s = new StringBuilder();
            for (int i = 0; i < 512; i++) {
                byte b = currentProgram.getMemory().getByte(a.add(i));
                if (b == 0) return s.toString();
                s.append((char) (b & 0xff));
            }
        } catch (Exception e) {
            return null;
        }
        return null;
    }
}
