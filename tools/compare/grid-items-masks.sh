#!/bin/bash
# Print the --mask arguments of frame-compare for the grid-items-still scene
# (grid spec, "打开后的静止画面"), one per line, in points with the origin at the
# top left of the 1536 x 960 display (REF-ENV-004):
#   - the Dock and the two VMs' recording indicators, as overlay-shell-still
#     (REF-ENV-005)
#   - the icon layer of every app on the first page (REF-GRID-010) and the mini
#     icon grid of every folder (REF-GRID-013), because the icons are the host
#     system's (REF-DEV-021)
#   - with --chinese-names, also the name layer of every app whose name has
#     Chinese characters (REF-DEV-022), for the first of the two comparisons
#   - with --menu-bar, also the menu bar, as overlay-shell-open and -close
#     (REF-DEV-001, REF-ENV-005)
#   - with --search-field, also the search field (the search-field-* scenes of
#     the search spec), whose images are this project's own drawings and whose
#     Chinese placeholder's glyphs are the system's (REF-DEV-022)
# With --zoom <scale> --anchor <x>,<y> (the grid-animation-* scenes), every
# icon, mini icon grid and name rectangle covers the whole area it sweeps while
# the main grid layer zooms between 1 and <scale> about the anchor (points,
# origin at the top left): the bounding box of the rectangle at both scales,
# rounded outward to whole points. The Dock, indicator and menu bar masks do
# not zoom.
# With --launch <title> (the launch-click scene), also the area the zoomed copy
# of that app's icon covers when it is clicked: its icon layer's rectangle
# scaled about its centre to the zoom's end scale (REF-LAUNCH-002). The copy
# sits on the window's root layer, outside the main grid, so --zoom does not
# widen it.
# With --page-control (the page-control-* scenes of the paging spec), the Dock
# mask starts at y 849, the row below the page indicators, which lie at y
# 833-848 with the default Dock (REF-PAGING-003), so that they are compared.
# With --sweep-pages <scene file> (page-control-click), the first page and the
# second page of that file slide across the whole width while the page
# changes, so every row that holds an icon layer or a mini icon grid on either
# page is masked as a band across the whole display at the icon layer's
# height (the mini icon grid's when the row holds only folders); with
# --chinese-names, also a band at the height of each Chinese name layer of the
# two pages. --sweep-pages cannot be combined with --zoom or --launch.
# The cells follow the original's default geometry (REF-GRID-004, REF-GRID-007,
# REF-GRID-008), which the comparison VM reproduces with REF-ENV-007; the page
# positions follow grid-items-scene.tsv (a folder takes the position of its
# first app).
#
# Usage: tools/compare/grid-items-masks.sh [--chinese-names] [--menu-bar] [--search-field] [--zoom <scale> --anchor <x>,<y>] [--launch <title>]
#        [--page-control] [--sweep-pages <scene file>]

set -euo pipefail

usage() { echo "usage: $0 [--chinese-names] [--menu-bar] [--search-field] [--zoom <scale> --anchor <x>,<y>] [--launch <title>] [--page-control] [--sweep-pages <scene file>]" >&2; exit 2; }
chinese=0
menu_bar=0
search_field=0
zoom=
anchor=
launch=
page_control=0
sweep=
while [[ $# -gt 0 ]]; do
    case $1 in
        --chinese-names) chinese=1 ;;
        --menu-bar) menu_bar=1 ;;
        --search-field) search_field=1 ;;
        --zoom) [[ $# -ge 2 ]] || usage; zoom=$2; shift ;;
        --anchor) [[ $# -ge 2 ]] || usage; anchor=$2; shift ;;
        --launch) [[ $# -ge 2 ]] || usage; launch=$2; shift ;;
        --page-control) page_control=1 ;;
        --sweep-pages) [[ $# -ge 2 ]] || usage; sweep=$2; shift ;;
        *) usage ;;
    esac
    shift
done
[[ -z $zoom && -z $anchor ]] || [[ -n $zoom && $anchor == *,* ]] || usage
[[ -z $sweep ]] || [[ -z $zoom && -z $launch && -f $sweep ]] || usage
repo=$(cd "$(dirname "$0")/../.." && pwd)
scene="$repo/tools/compare/grid-items-scene.tsv"

display_height=960  # REF-ENV-004
# The first page in the overlay's coordinates (origin at the bottom left): the main grid's y 101
# (REF-GRID-004) plus the scroll layer's y 37, and the page frame (151, 0, 1234, 757) in it (REF-GRID-007).
page_x=151
page_y=$((101 + 37))
page_height=757
columns=7
column_width=176  # REF-GRID-008
row_height=151    # REF-GRID-008
# Inside an item layer (origin at its bottom left): the icon layer (REF-GRID-010), a folder's mini icon
# grid (REF-GRID-013), and the name layers measured for Chinese names (REF-GRID-010).
icon=(36 42 104 104)
launch_scale=2  # REF-LAUNCH-002: the zoomed copy's end scale
mini_grid=(54 60 68 68)
name_layer() {
    case $1 in
        测试应用) echo 60 19 57 23 ;;
    esac
}

# REF-ENV-005: the Dock, and the recording and privacy indicators of both VMs. With --page-control the
# Dock mask starts below the page indicators (REF-PAGING-003).
if ((page_control)); then
    echo "--mask 16,849,1504,111"
else
    echo "--mask 16,832,1504,128"
fi
echo "--mask 1320,0,200,24"
echo "--mask 1520,0,16,16"
if ((menu_bar)); then
    echo "--mask 0,0,1536,80"
fi

# Prints a --mask line for the rectangle (x, y, w, h) in display points, widened to the area it
# sweeps under --zoom.
emit() {
    if [[ -z $zoom ]]; then
        echo "--mask $1,$2,$3,$4"
        return
    fi
    awk -v x="$1" -v y="$2" -v w="$3" -v h="$4" -v s="$zoom" -v a="$anchor" 'BEGIN {
        split(a, p, ",")
        x2 = p[1] + s * (x - p[1]); y2 = p[2] + s * (y - p[2])
        l = (x < x2 ? x : x2); t = (y < y2 ? y : y2)
        r = (x + w > x2 + s * w ? x + w : x2 + s * w); b = (y + h > y2 + s * h ? y + h : y2 + s * h)
        l = int(l); if (l > x || l > x2) l = l - 1
        t = int(t); if (t > y || t > y2) t = t - 1
        r = (r == int(r)) ? r : int(r) + 1; b = (b == int(b)) ? b : int(b) + 1
        printf "--mask %d,%d,%d,%d\n", l, t, r - l, b - t
    }'
}

# --search-field: the field's frame in the main grid (0, 101, 1536, 859) (REF-GRID-004): x = midX - 125,
# y = maxY - (0 + 35 + 25 - 10) with no notch and the top margin 35, 250 x 25 (REF-SEARCH-002).
if ((search_field)); then
    field_height=25
    field_y=$((101 + 859 - (0 + 35 + field_height - 10)))
    emit "$((1536 / 2 - 125))" "$((display_height - (field_y + field_height)))" 250 "$field_height"
fi

# A rectangle (x, y, w, h) inside the item layer at page position $1, as a --mask line.
mask_in_cell() {
    local position=$1 x=$2 y=$3 w=$4 h=$5
    local column=$((position % columns)) row=$((position / columns))
    local cell_x=$((page_x + column * column_width))
    local cell_y=$((page_y + page_height - (row + 1) * row_height))
    emit "$((cell_x + x))" "$((display_height - (cell_y + y + h)))" "$w" "$h"
}

# --sweep-pages: one band across the display for the rectangle (x, y, w, h) inside an item layer of
# row $1, printed as "top,height", once per row and rectangle after sorting.
if [[ -n $sweep ]]; then
    band_in_row() {
        local row=$1 y=$3 h=$5
        local cell_y=$((page_y + page_height - (row + 1) * row_height))
        echo "$((display_height - (cell_y + y + h))),$h"
    }
    for file in "$scene" "$sweep"; do
        position=-1
        folder=
        while IFS=$'\t' read -r title folder_title; do
            [[ $title == \#* ]] && continue
            if [[ -n $folder_title ]]; then
                [[ $folder_title == "$folder" ]] && continue
                folder=$folder_title
                position=$((position + 1))
                band_in_row "$((position / columns))" "${mini_grid[@]}"
                continue
            fi
            folder=
            position=$((position + 1))
            band_in_row "$((position / columns))" "${icon[@]}"
            if ((chinese)) && LC_ALL=C grep -q '[^ -~]' <<<"$title"; then
                frame=$(name_layer "$title")
                [[ -n $frame ]] || { echo "no measured name layer for $title" >&2; exit 1; }
                # shellcheck disable=SC2086
                band_in_row "$((position / columns))" $frame
            fi
        done < "$file"
    done | sort -t, -k1,1n -k2,2n -u | while IFS=, read -r top height; do
        echo "--mask 0,$top,1536,$height"
    done
    exit 0
fi

position=-1
folder=
while IFS=$'\t' read -r title folder_title; do
    [[ $title == \#* ]] && continue
    if [[ -n $folder_title ]]; then
        [[ $folder_title == "$folder" ]] && continue
        folder=$folder_title
        position=$((position + 1))
        mask_in_cell "$position" "${mini_grid[@]}"
        continue
    fi
    folder=
    position=$((position + 1))
    mask_in_cell "$position" "${icon[@]}"
    if [[ $title == "$launch" ]]; then
        launch_found=1
        # The icon layer's rectangle scaled about its centre, in the item layer's coordinates.
        read -r lx ly lw lh < <(awk -v x="${icon[0]}" -v y="${icon[1]}" -v w="${icon[2]}" -v h="${icon[3]}" -v s="$launch_scale" \
            'BEGIN { printf "%d %d %d %d\n", x + w / 2 - s * w / 2, y + h / 2 - s * h / 2, s * w, s * h }')
        saved_zoom=$zoom
        zoom=
        mask_in_cell "$position" "$lx" "$ly" "$lw" "$lh"
        zoom=$saved_zoom
    fi
    if ((chinese)) && LC_ALL=C grep -q '[^ -~]' <<<"$title"; then
        frame=$(name_layer "$title")
        [[ -n $frame ]] || { echo "no measured name layer for $title" >&2; exit 1; }
        # shellcheck disable=SC2086
        mask_in_cell "$position" $frame
    fi
done < "$scene"
[[ -z $launch || -n ${launch_found:-} ]] || { echo "no app titled $launch on the first page" >&2; exit 1; }
