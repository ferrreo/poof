# Packaged Sublime Syntax Corpus

Upstream `.sublime-syntax` files from `sublimehq/Packages` commit
`d9b8221ee37ef8f6376f33ac53a175c08962f516` are materialized into the corpus
cache.

`tools/update_sublime_packs.sh` reconstructs each syntax in `/tmp`, converts it
offline to native `.zhl`, and writes checked `.zhlb` packs to
`grammars/sublime-packs`.

Included syntaxes are the cached `*.sublime-syntax.part00` files. There are
currently 113 split upstream syntax sources. Integration checks
reconstruct each source, verify `missing=0`, convert it offline to native
`.zhl`, compile generated Zig, and compare regenerated packs for non-hidden
syntaxes against `grammars/sublime-packs`.

License: `LICENSE`.
