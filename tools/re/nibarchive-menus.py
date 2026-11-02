#!/usr/bin/env python3
"""Prints the menus of a compiled NIBArchive nib in menu order.

Usage: nibarchive-menus.py <MainMenu.nib>

For every NSMenu: its title and name, then each item of its NSMenuItems array in order with
title, key equivalent, modifier mask, tag, separator, disabled, hidden, alternate, tooltip, its
target-action connection (selector and destination) and its submenu. Objects that are not menus
or menu items but are the destination of a menu item's action are listed at the end.
"""
import struct
import sys


def varint(data, pos):
    # NIBArchive varints: 7 bits per byte, little-endian; the high bit marks the LAST byte.
    value, shift = 0, 0
    while True:
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if byte & 0x80:
            return value, pos


def parse(data):
    assert data[:10] == b"NIBArchive", "not a NIBArchive"
    (object_count, objects_offset, key_count, keys_offset,
     value_count, values_offset, class_count, classes_offset) = struct.unpack_from("<8I", data, 18)

    keys, pos = [], keys_offset
    for _ in range(key_count):
        length, pos = varint(data, pos)
        keys.append(data[pos:pos + length].decode())
        pos += length

    classes, pos = [], classes_offset
    for _ in range(class_count):
        length, pos = varint(data, pos)
        extra, pos = varint(data, pos)
        pos += 4 * extra
        classes.append(data[pos:pos + length].rstrip(b"\0").decode())
        pos += length

    values, pos = [], values_offset
    for _ in range(value_count):
        key, pos = varint(data, pos)
        kind = data[pos]
        pos += 1
        if kind == 0:
            value = data[pos]; pos += 1
        elif kind == 1:
            value = struct.unpack_from("<h", data, pos)[0]; pos += 2
        elif kind == 2:
            value = struct.unpack_from("<i", data, pos)[0]; pos += 4
        elif kind == 3:
            value = struct.unpack_from("<q", data, pos)[0]; pos += 8
        elif kind == 4:
            value = False
        elif kind == 5:
            value = True
        elif kind == 6:
            value = struct.unpack_from("<f", data, pos)[0]; pos += 4
        elif kind == 7:
            value = struct.unpack_from("<d", data, pos)[0]; pos += 8
        elif kind == 8:
            length, pos = varint(data, pos)
            value = bytes(data[pos:pos + length]); pos += length
        elif kind == 9:
            value = None
        elif kind == 10:
            value = ("ref", struct.unpack_from("<I", data, pos)[0]); pos += 4
        else:
            raise ValueError(f"value type {kind}")
        values.append((keys[key], value))

    objects, pos = [], objects_offset
    for _ in range(object_count):
        cls, pos = varint(data, pos)
        first, pos = varint(data, pos)
        count, pos = varint(data, pos)
        objects.append((classes[cls], values[first:first + count]))
    return objects


def field(obj, key):
    for k, v in obj[1]:
        if k == key:
            return v
    return None


def elements(objects, ref):
    # NSArray: its elements are the values under UINibEncoderEmptyKey, in order.
    return [v[1] for k, v in objects[ref[1]][1] if k == "UINibEncoderEmptyKey"]


def string(objects, value):
    if isinstance(value, tuple):
        obj = objects[value[1]]
        raw = field(obj, "NS.bytes")
        if raw is None:
            raw = field(obj, "NS.string")
        return raw.decode() if isinstance(raw, bytes) else raw
    return value


def main(path):
    objects = parse(open(path, "rb").read())
    actions = {}
    for cls, vals in objects:
        if cls == "NSNibControlConnector":
            obj = (cls, vals)
            source = field(obj, "NSSource")
            destination = field(obj, "NSDestination")
            actions[source[1]] = (string(objects, field(obj, "NSLabel")),
                                  None if destination is None else destination[1])

    def describe(index):
        if index is None:
            return "First Responder"
        cls, _ = objects[index]
        return f"#{index} {cls}"

    destinations = set()
    for index, obj in enumerate(objects):
        if obj[0] != "NSMenu":
            continue
        print(f"NSMenu #{index} title={string(objects, field(obj, 'NSTitle'))!r} "
              f"name={string(objects, field(obj, 'NSName'))!r}")
        items = field(obj, "NSMenuItems")
        for position, ref in enumerate(elements(objects, items) if items else []):
            item = objects[ref]
            submenu = field(item, "NSSubmenu")
            action = actions.get(ref)
            if action:
                destinations.add(action[1])
            flags = [name for name, key in (("separator", "NSIsSeparator"), ("disabled", "NSIsDisabled"),
                                             ("hidden", "NSIsHidden"), ("alternate", "NSIsAlternate"))
                     if field(item, key)]
            print(f"  {position:2} #{ref} title={string(objects, field(item, 'NSTitle'))!r} "
                  f"key={string(objects, field(item, 'NSKeyEquiv'))!r} "
                  f"mods={field(item, 'NSKeyEquivModMask')} tag={field(item, 'NSTag')} "
                  f"{' '.join(flags)} "
                  f"action={None if action is None else action[0]!r} "
                  f"target={None if action is None else describe(action[1])} "
                  f"submenu={None if submenu is None else '#' + str(submenu[1])}"
                  + (f" tooltip={string(objects, field(item, 'NSToolTip'))!r}" if field(item, "NSToolTip") else ""))
    for index in sorted(d for d in destinations if d is not None):
        cls, vals = objects[index]
        print(f"#{index} {cls}: {[k for k, _ in vals]}")


if __name__ == "__main__":
    main(sys.argv[1])
