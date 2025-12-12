#!/bin/bash

# export NVIM_ROOT=/usr/src/debug/neovim-git/neovim/
# export NVIM=
# includes=$(nvim --headless tmp_pseudoheader.h +q 2>&1 | rg --only-matching '#include\s+"([^"]+)"' -r '$1')
#
# while IFS= read -r relpath; do
#   src=$(fd -I --full-path "/$relpath" "$HOME/b/neovim" | head -n1)
#   if [ -n "$src" ]; then
#     dst=patch/${src#"$HOME/b/neovim/"}
#     mkdir -p "$(dirname "$dst")"
#     cp "$src" "$dst"
#     echo "$src -> $dst"
#   fi
# done <<<"$includes"

SRC1="$HOME/b/neovim"
SRC2="/usr/src/debug/neovim-git/neovim"
EXCLUDE_DIRS=(".zig-cache" ".vim-src" ".deps")

build_find_exclude() {
  local base="$1"
  local args=()
  for d in "${EXCLUDE_DIRS[@]}"; do
    args+=(-path "$base/$d" -prune -o)
  done
  echo "${args[@]}"
}

EXCLUDE1=($(build_find_exclude "$SRC1"))
EXCLUDE2=($(build_find_exclude "$SRC2"))

find "$SRC1" "${EXCLUDE1[@]}" -type f -name '*.h' -print | sed "s|^$SRC1/||" | sort >/tmp/b_neovim_h.txt
find "$SRC2" "${EXCLUDE2[@]}" -type f -name '*.h' -print | sed "s|^$SRC2/||" | sort >/tmp/usr_neovim_h.txt

comm -23 /tmp/b_neovim_h.txt /tmp/usr_neovim_h.txt | while read -r relpath; do
  mkdir -p "./patch/$(dirname "$relpath")"
  touch "./patch/$relpath"
  echo "created ./patch/$relpath"
done
