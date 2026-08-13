# External Sublime Syntax Corpus

Files in this directory are split chunks of upstream `.sublime-syntax` files
from `sublimehq/Packages` commit
`d9b8221ee37ef8f6376f33ac53a175c08962f516`.

`tools/check_integrations.sh` reconstructs them in `/tmp` and runs import,
offline conversion, native grammar validation, generated Zig compilation, and
Zig tests.

Included syntaxes:

- `C++/C.sublime-syntax`
- `CSS/CSS.sublime-syntax`
- `Diff/Diff.sublime-syntax`
- `Git Formats/Git Config.sublime-syntax`
- `Go/Go.sublime-syntax`
- `HTML/HTML.sublime-syntax`
- `Java/JavaProperties.sublime-syntax`
- `JSON/JSON.sublime-syntax`
- `JavaScript/JavaScript.sublime-syntax`
- `Lua/Lua.sublime-syntax`
- `Markdown/Markdown.sublime-syntax`
- `Python/Python.sublime-syntax`
- `Rust/Rust.sublime-syntax`
- `TOML/TOML.sublime-syntax`
- `JavaScript/TypeScript.sublime-syntax`
- `XML/XML.sublime-syntax`
- `YAML/YAML.sublime-syntax`

Hidden parent syntaxes used by `extends`:

- `Diff/Diff (Basic).sublime-syntax`
- `HTML/HTML (Plain).sublime-syntax`

License: `LICENSE`.
