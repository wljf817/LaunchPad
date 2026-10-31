#!/bin/bash
# Lay out the first page of the grid-items-still scene in a VM's Launchpad
# database, export a page, or restore the database. Works on the reference VM
# (macOS 15: Dock's database, Dock restarted) and on the comparison VM
# (macOS 26: this project's database, REF-DEV-002, its background process
# restarted); the system is told apart by sw_vers. Needs key-based SSH login.
#
#   backup   copy the database (sqlite3 .backup) to ~/grid-items-backup/db,
#            unless a backup is already there
#   apply    with the test apps of grid-items-apps.sh already in the
#            database: stop the process (SIGSTOP), move the first page's items
#            to a new second page, put the scene's items on the first page in
#            the order of grid-items-scene.tsv (folders created with the given
#            titles), drop folders and pages left empty, renumber the root's
#            pages, then kill the process so that it restarts and reads the
#            database (R7)
#   export   print the first page: position, type, title, bundle identifier,
#            and every folder's apps
#   restore  stop the process, put the backup back, kill the process
#   apply-paging
#            the page-control-* scenes (paging spec), with the test apps of
#            grid-items-apps.sh --paging in the database: as apply, then puts
#            the apps of page-control-scene.tsv on a new second page and every
#            other item of the root's pages on a third page, the folders as
#            they are and every other app in one folder titled LPPage Rest,
#            so that the root has exactly three pages on both systems; the
#            process's start splits that folder's page as it needs
#   export-paging
#            print the first page as export does, a line "--", the second
#            page the same way, and a last line "pages <n>" with the number
#            of the root's pages (without the hidden page)
#
# Usage: tools/compare/grid-items-layout.sh <user>@<vm-address> backup|apply|export|restore|apply-paging|export-paging

set -euo pipefail

[[ $# -eq 2 ]] || { echo "usage: $0 <user>@<vm-address> backup|apply|export|restore|apply-paging|export-paging" >&2; exit 2; }
vm_dest=$1
action=$2
repo=$(cd "$(dirname "$0")/../.." && pwd)
scene="$repo/tools/compare/grid-items-scene.tsv"
paging_scene="$repo/tools/compare/page-control-scene.tsv"

vm() { ssh -o BatchMode=yes "$vm_dest" "$@"; }

if [[ $(vm sw_vers -productVersion) == 15.* ]]; then
    db_dir='$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db'
    process=Dock
else
    db_dir='$(getconf DARWIN_USER_DIR)io.github.wljf817.LaunchPad.launchpad/db'
    process=LaunchPadAgent
fi

# SQL that builds the scene's first page, without the cleanup and the commit.
first_page_sql() {
    local n=0 k=-1 last_folder= folder_id= page_ordering=0 folder_page=
    cat <<'EOF'
BEGIN;
UPDATE dbinfo SET value = 1 WHERE key = 'ignore_items_update_triggers';
CREATE TEMP TABLE first AS SELECT rowid AS id, flags, ordering FROM items
    WHERE parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root') AND type = 3 AND ordering >= 1
    ORDER BY ordering LIMIT 1;
UPDATE items SET ordering = ordering + 1
    WHERE parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root') AND type = 3 AND ordering > (SELECT ordering FROM first);
EOF
    echo "INSERT INTO items (uuid, flags, type, parent_id, ordering) SELECT '$(uuidgen)', flags, 3, (SELECT value FROM dbinfo WHERE key = 'launchpad_root'), ordering + 1 FROM first;"
    echo "CREATE TEMP TABLE second AS SELECT last_insert_rowid() AS id;"
    echo "INSERT INTO groups (item_id) SELECT id FROM second;"
    echo "UPDATE items SET parent_id = (SELECT id FROM second) WHERE parent_id = (SELECT id FROM first);"
    while IFS=$'\t' read -r title folder; do
        n=$((n + 1))
        bundle="io.github.wljf817.lptest.grid.$n"
        if [[ -z $folder ]]; then
            k=$((k + 1))
            last_folder=
            echo "UPDATE items SET parent_id = (SELECT id FROM first), ordering = $k WHERE rowid = (SELECT item_id FROM apps WHERE bundleid = '$bundle');"
        else
            if [[ $folder != "$last_folder" ]]; then
                k=$((k + 1))
                last_folder=$folder
                page_ordering=0
                local sql_title=${folder//\'/\'\'}
                echo "INSERT INTO items (uuid, flags, type, parent_id, ordering) VALUES ('$(uuidgen)', 0, 2, (SELECT id FROM first), $k);"
                echo "INSERT INTO groups (item_id, title) VALUES (last_insert_rowid(), '$sql_title');"
                echo "INSERT INTO items (uuid, flags, type, parent_id, ordering) VALUES ('$(uuidgen)', 0, 3, (SELECT max(rowid) FROM items WHERE type = 2), 0);"
                echo "INSERT INTO groups (item_id) VALUES (last_insert_rowid());"
            fi
            echo "UPDATE items SET parent_id = (SELECT max(rowid) FROM items WHERE type = 3), ordering = $page_ordering WHERE rowid = (SELECT item_id FROM apps WHERE bundleid = '$bundle');"
            page_ordering=$((page_ordering + 1))
        fi
    done < <(grep -v '^#' "$scene")
}

# SQL that adds the second and third pages of the page-control-* scenes after first_page_sql: page 2
# holds the apps of page-control-scene.tsv in order; page 3 the folders of the other root pages, in
# page and position order, after a new folder LPPage Rest holding every other app of those pages.
paging_sql() {
    local n=0
    cat <<'EOF'
UPDATE items SET ordering = ordering + 2
    WHERE parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root') AND type = 3 AND ordering > (SELECT ordering FROM first);
EOF
    echo "INSERT INTO items (uuid, flags, type, parent_id, ordering) SELECT '$(uuidgen)', flags, 3, (SELECT value FROM dbinfo WHERE key = 'launchpad_root'), ordering + 1 FROM first;"
    echo "CREATE TEMP TABLE page2 AS SELECT last_insert_rowid() AS id;"
    echo "INSERT INTO groups (item_id) SELECT id FROM page2;"
    echo "INSERT INTO items (uuid, flags, type, parent_id, ordering) SELECT '$(uuidgen)', flags, 3, (SELECT value FROM dbinfo WHERE key = 'launchpad_root'), ordering + 2 FROM first;"
    echo "CREATE TEMP TABLE page3 AS SELECT last_insert_rowid() AS id;"
    echo "INSERT INTO groups (item_id) SELECT id FROM page3;"
    while IFS=$'\t' read -r title _; do
        n=$((n + 1))
        echo "UPDATE items SET parent_id = (SELECT id FROM page2), ordering = $((n - 1)) WHERE rowid = (SELECT item_id FROM apps WHERE bundleid = 'io.github.wljf817.lptest.page.$n');"
    done < <(grep -v '^#' "$paging_scene")
    echo "INSERT INTO items (uuid, flags, type, parent_id, ordering) VALUES ('$(uuidgen)', 0, 2, (SELECT id FROM page3), 0);"
    echo "CREATE TEMP TABLE rest AS SELECT last_insert_rowid() AS id;"
    echo "INSERT INTO groups (item_id, title) SELECT id, 'LPPage Rest' FROM rest;"
    echo "INSERT INTO items (uuid, flags, type, parent_id, ordering) SELECT '$(uuidgen)', 0, 3, id, 0 FROM rest;"
    echo "CREATE TEMP TABLE rest_page AS SELECT last_insert_rowid() AS id;"
    echo "INSERT INTO groups (item_id) SELECT id FROM rest_page;"
    cat <<'EOF'
-- Items on the other root pages (the hidden page, ordering 0, excluded), in page and position order.
CREATE TEMP TABLE others AS SELECT i.rowid AS id, i.type AS type,
    row_number() OVER (PARTITION BY i.type = 2 ORDER BY p.ordering, i.ordering) AS k
    FROM items i JOIN items p ON p.rowid = i.parent_id
    WHERE p.parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root') AND p.type = 3 AND p.ordering >= 1
      AND p.rowid NOT IN ((SELECT id FROM first), (SELECT id FROM page2), (SELECT id FROM page3));
UPDATE items SET parent_id = (SELECT id FROM rest_page), ordering = (SELECT k - 1 FROM others WHERE others.id = items.rowid)
    WHERE rowid IN (SELECT id FROM others WHERE type IN (4, 5));
UPDATE items SET parent_id = (SELECT id FROM page3), ordering = (SELECT k FROM others WHERE others.id = items.rowid)
    WHERE rowid IN (SELECT id FROM others WHERE type = 2);
EOF
}

# SQL that removes what the page building left empty, renumbers the root's pages and commits.
cleanup_sql() {
    cat <<'EOF'
-- Folders without apps left (pages of the root excluded), then their pages, then empty root pages.
CREATE TEMP TABLE empty_folders AS SELECT g.rowid AS id FROM items g WHERE g.type = 2
    AND NOT EXISTS (SELECT 1 FROM items p JOIN items a ON a.parent_id = p.rowid WHERE p.parent_id = g.rowid AND a.type IN (4, 5));
DELETE FROM items WHERE parent_id IN (SELECT id FROM empty_folders);
DELETE FROM items WHERE rowid IN (SELECT id FROM empty_folders);
DELETE FROM items WHERE type = 3 AND parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root') AND ordering >= 1
    AND rowid != (SELECT id FROM first) AND NOT EXISTS (SELECT 1 FROM items c WHERE c.parent_id = items.rowid);
UPDATE items SET ordering = (SELECT count(*) FROM items p WHERE p.parent_id = items.parent_id AND p.type = 3 AND p.ordering >= 1 AND p.ordering <= items.ordering)
    WHERE type = 3 AND parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root') AND ordering >= 1;
UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers';
COMMIT;
EOF
}

# SQL that builds the scene's first page.
apply_sql() {
    first_page_sql
    cleanup_sql
}

# SQL that builds the three pages of the page-control-* scenes.
apply_paging_sql() {
    first_page_sql
    paging_sql
    cleanup_sql
}

# SQL that prints a root page, by default the first (OFFSET $1).
export_sql() {
    cat <<EOF
WITH first AS (SELECT rowid AS id FROM items WHERE parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root')
                   AND type = 3 AND ordering >= 1 ORDER BY ordering LIMIT 1 OFFSET ${1:-0})
SELECT i.ordering, i.type, coalesce(a.title, g.title), coalesce(a.bundleid, ''),
       (SELECT group_concat(t, ', ') FROM (SELECT a2.title AS t FROM items p JOIN items c ON c.parent_id = p.rowid
            JOIN apps a2 ON a2.item_id = c.rowid WHERE p.parent_id = i.rowid ORDER BY p.ordering, c.ordering))
FROM items i LEFT JOIN apps a ON a.item_id = i.rowid LEFT JOIN groups g ON g.item_id = i.rowid
WHERE i.parent_id = (SELECT id FROM first) ORDER BY i.ordering;
EOF
}

case $action in
    backup)
        vm "set -e; d=\"$db_dir\"; mkdir -p ~/grid-items-backup; if [ -e ~/grid-items-backup/db ]; then echo 'backup already there'; else sqlite3 \"\$d/db\" '.backup /Users/'\$(id -un)'/grid-items-backup/db'; echo backed up; fi"
        ;;
    apply)
        apply_sql > /tmp/grid-items-layout.$$.sql
        scp -o BatchMode=yes -q /tmp/grid-items-layout.$$.sql "$vm_dest:/tmp/grid-items-layout.sql"
        rm -f /tmp/grid-items-layout.$$.sql
        vm "set -e; d=\"$db_dir\"; pid=\$(pgrep -x $process); kill -STOP \$pid; sqlite3 -bail \"\$d/db\" < /tmp/grid-items-layout.sql || { kill -CONT \$pid; exit 1; }; kill -KILL \$pid; echo applied"
        ;;
    export)
        export_sql > /tmp/grid-items-export.$$.sql
        scp -o BatchMode=yes -q /tmp/grid-items-export.$$.sql "$vm_dest:/tmp/grid-items-export.sql"
        rm -f /tmp/grid-items-export.$$.sql
        vm "d=\"$db_dir\"; sqlite3 -separator '	' \"\$d/db\" < /tmp/grid-items-export.sql"
        ;;
    apply-paging)
        apply_paging_sql > /tmp/grid-items-layout.$$.sql
        scp -o BatchMode=yes -q /tmp/grid-items-layout.$$.sql "$vm_dest:/tmp/grid-items-layout.sql"
        rm -f /tmp/grid-items-layout.$$.sql
        vm "set -e; d=\"$db_dir\"; pid=\$(pgrep -x $process); kill -STOP \$pid; sqlite3 -bail \"\$d/db\" < /tmp/grid-items-layout.sql || { kill -CONT \$pid; exit 1; }; kill -KILL \$pid; echo applied"
        ;;
    export-paging)
        { export_sql 0; echo "SELECT '--';"; export_sql 1
          echo "SELECT 'pages ' || count(*) FROM items WHERE parent_id = (SELECT value FROM dbinfo WHERE key = 'launchpad_root') AND type = 3 AND ordering >= 1;"
        } > /tmp/grid-items-export.$$.sql
        scp -o BatchMode=yes -q /tmp/grid-items-export.$$.sql "$vm_dest:/tmp/grid-items-export.sql"
        rm -f /tmp/grid-items-export.$$.sql
        vm "d=\"$db_dir\"; sqlite3 -separator '	' \"\$d/db\" < /tmp/grid-items-export.sql"
        ;;
    restore)
        vm "set -e; d=\"$db_dir\"; [ -e ~/grid-items-backup/db ]; pid=\$(pgrep -x $process); kill -STOP \$pid; cp ~/grid-items-backup/db \"\$d/db\"; rm -f \"\$d/db-wal\" \"\$d/db-shm\"; kill -KILL \$pid; echo restored"
        ;;
    *)
        echo "usage: $0 <user>@<vm-address> backup|apply|export|restore|apply-paging|export-paging" >&2
        exit 2
        ;;
esac
