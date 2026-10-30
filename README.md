# lua-lolhtml

Lua bindings for [lol-html][lolhtml], Cloudflare's streaming HTML parser and
rewriter with a CSS selector-based API. Use it to modify HTML as it arrives or
extract attributes and text without building a DOM for the whole document.

The LuaRocks package is **`lua-lolhtml`**; load it with **`require "lolhtml"`**.
The current release is **1.1.0**, built with **lol-html 3.0.3**. It supports:

- CSS selectors for element, descendant text, and comment handlers.
- Document-wide handlers for text, comments, DOCTYPE declarations, and EOF.
- Attribute changes, tag renaming, content insertion, replacement, and removal.
- Extraction without an output callback, using a native discard sink.
- Original-case names, element structure queries, and input byte positions for
  elements, comments, and DOCTYPE declarations.

## Contents

- [Installation](#installation)
- [Quick start](#quick-start)
- [Streaming input and output](#streaming-input-and-output)
- [Examples](#examples)
- [Execution and object lifetime](#execution-and-object-lifetime)
- [API reference](#api-reference)
- [OpenResty](#openresty)
- [Development and tests](#development-and-tests)
- [License](#license)

## Installation

### Requirements

Building the native module requires Rust **1.89 or newer**, Cargo, a C compiler,
Make, and development headers for the Lua interpreter that will load it. Install
Rust using [rustup][rust-install] or a suitable distribution package. Rust and
Cargo are build dependencies; they are not needed to run an installed module.

The rockspec declares support for Lua 5.1 through 5.3, including LuaJIT's Lua 5.1
API. CI builds and tests with LuaJIT 2.1 on Linux using both Rust 1.89 and the
current stable Rust toolchain. Lua 5.4 is not declared supported by the rockspec.

For example, install the C and LuaJIT dependencies on Debian or Ubuntu with:

```sh
sudo apt-get install build-essential libluajit-5.1-dev luajit
```

### LuaRocks

Use LuaRocks 3.0 or newer, configured for the intended Lua interpreter:

```sh
luarocks install lua-lolhtml 1.1.0-1
```

The source rock includes the pinned native dependencies. Cargo also downloads
the Rust dependencies recorded in their lockfile on the first build. Installation
compiles a native `lolhtml.so`, so the Lua headers and module search path must
match the interpreter used by your application.

If your OpenResty installation includes its own LuaRocks executable, use it:

```sh
/usr/local/openresty/luajit/bin/luarocks install lua-lolhtml 1.1.0-1
```

For a separately installed LuaRocks, configure it for OpenResty's LuaJIT. A module
built for a different Lua ABI cannot be loaded just by changing `package.cpath`.

### Build from source

Clone the release with its submodules:

```sh
git clone --branch 1.1.0 --recurse-submodules \
  https://github.com/HanadaLee/lua-lolhtml.git
cd lua-lolhtml
luarocks make rockspecs/lua-lolhtml-1.1.0-1.rockspec
```

For an existing checkout, run `git submodule update --init --recursive` after
switching revisions. You can also build directly with Make; for LuaJIT on Debian
or Ubuntu:

```sh
make CFLAGS="-O2 -fPIC -I/usr/include/luajit-2.1"
LUA_CPATH="$PWD/?.so;;" luajit -e 'assert(require "lolhtml")'
```

Adjust the include directory for your installation. The Makefile produces
`lolhtml.so` in the repository root; it does not install it into a Lua module path.

## Quick start

Create a builder, register handlers, and create one rewriter per document. Check
the return values of operations that can fail, then call `close()` to finish.

```lua
local lolhtml = require "lolhtml"
local output = {}
local builder = lolhtml.new_rewriter_builder()

assert(builder:add_element_content_handlers {
  selector = assert(lolhtml.new_selector("h1")),
  element_handler = function(element)
    assert(element:set_attribute("class", "title"))
  end,
})

local rewriter = assert(lolhtml.new_rewriter {
  builder = builder,
  sink = function(chunk)
    output[#output + 1] = chunk
  end,
})

assert(rewriter:write("<h1>Hello, "))
assert(rewriter:write("Lua!</h1>"))
assert(rewriter:close())

local html = table.concat(output)
assert(html == '<h1 class="title">Hello, Lua!</h1>')
io.write(html, "\n")
```

Collecting output in a Lua table is convenient for small documents. For larger
inputs, send chunks directly to a suitable destination instead of retaining the
whole result.

## Streaming input and output

`write(chunk)` accepts arbitrary pieces of the input byte stream. A tag, attribute,
or multibyte character may span several calls. Input chunk boundaries do not
determine handler boundaries or output chunk boundaries.

The sink receives strings synchronously while `write()` and `close()` run. Its
return values are ignored. It may receive several chunks for one input write,
including an empty string at EOF. Use `io.write`, not `print`, to reproduce the
output stream without inserting newlines between chunks.

This complete filter removes HTML comments while preserving input line endings:

```lua
local lolhtml = require "lolhtml"
local builder = lolhtml.new_rewriter_builder()

builder:add_document_content_handlers {
  comment_handler = function(comment)
    comment:remove()
  end,
}

local rewriter = assert(lolhtml.new_rewriter {
  builder = builder,
  sink = function(chunk)
    assert(io.stdout:write(chunk))
  end,
})

while true do
  local chunk, err = io.stdin:read(8192)
  if not chunk then
    assert(not err, err)
    break
  end
  assert(rewriter:write(chunk))
end
assert(rewriter:close())
```

Always call `close()` after the final successful write, including for an empty
document. It flushes pending output and invokes document-end handlers. Garbage
collection frees native resources but does not finish the output stream.

Output already sent to the sink cannot be rolled back if a later write fails. A
failed or closed rewriter cannot be reused; create a new one for the next document.

## Examples

### Extract links and a title without producing HTML

Omit `sink` when only callback results are needed. Output is discarded in C, so
there is no Lua output callback to supply.

```lua
local lolhtml = require "lolhtml"
local links, title_parts = {}, {}
local builder = lolhtml.new_rewriter_builder()

assert(builder:add_element_content_handlers {
  selector = assert(lolhtml.new_selector("a[href]")),
  element_handler = function(element)
    links[#links + 1] = element:get_attribute("href")
  end,
})
assert(builder:add_element_content_handlers {
  selector = assert(lolhtml.new_selector("title")),
  text_handler = function(text)
    title_parts[#title_parts + 1] = text:get_text()
  end,
})

local rewriter = assert(lolhtml.new_rewriter { builder = builder })
assert(rewriter:write('<title>Lua '))
assert(rewriter:write('modules</title><a href="/docs">Read more</a>'))
assert(rewriter:close())

assert(table.concat(title_parts) == "Lua modules")
assert(links[1] == "/docs")
```

Text callbacks receive **fragments of text nodes**, not complete element text.
Accumulate the strings if the application needs a whole value.
`is_last_in_text_node()` marks the end of one text node and can be true for an
empty chunk. It does not mean that the containing element has ended:
`<p>one <b>two</b> three</p>` contains several text nodes.

`get_text()` and attribute values retain HTML character references such as
`&amp;`; they are not automatically entity-decoded. Character references can also
span text chunks. The Lua binding does not expose the Rust text-context API or an
entity decoder.

### Rename elements and change their content

```lua
local lolhtml = require "lolhtml"
local output = {}
local builder = lolhtml.new_rewriter_builder()

assert(builder:add_element_content_handlers {
  selector = assert(lolhtml.new_selector("div.notice")),
  element_handler = function(element)
    assert(element:set_tag_name("aside"))
    assert(element:set_attribute("role", "note"))
    assert(element:set_inner_content("Read <carefully> & enjoy"))
    assert(element:append("<strong>!</strong>", true))
  end,
})

local rewriter = assert(lolhtml.new_rewriter {
  builder = builder,
  sink = function(chunk) output[#output + 1] = chunk end,
})
assert(rewriter:write('<div class="notice">Old text</div>'))
assert(rewriter:close())
assert(table.concat(output) == '<aside class="notice" role="note">'
  .. 'Read &lt;carefully&gt; &amp; enjoy<strong>!</strong></aside>')
```

Insertion and replacement methods take an optional `is_html` argument:

| Value | Interpretation |
| --- | --- |
| Omitted, `nil`, or `false` | Text: escape `&`, `<`, and `>` before insertion. |
| `true` | HTML: insert the supplied markup without escaping it. |

Inserted content is not parsed again for selector callbacks. Text escaping is
for HTML text content; it is not JavaScript, CSS, or URL escaping. Attribute
setters have separate rules: `set_attribute()` escapes double quotes as needed
for serialization but preserves `&` and existing character references.

### Read original input positions and preserve name case

```lua
local lolhtml = require "lolhtml"
local input = '<DIV Data-ID="42">hello</DIV>'
local result
local builder = lolhtml.new_rewriter_builder()

assert(builder:add_element_content_handlers {
  selector = assert(lolhtml.new_selector("div")),
  element_handler = function(element)
    local first, last = element:source_location()
    result = {
      name = element:get_tag_name(true),
      source = input:sub(first, last),
      attributes = {},
    }
    for name, value in element:attributes(true) do
      result.attributes[name] = value
    end
  end,
})

local rewriter = assert(lolhtml.new_rewriter { builder = builder })
assert(rewriter:write(input))
assert(rewriter:close())
assert(result.name == "DIV")
assert(result.source == '<DIV Data-ID="42">')
assert(result.attributes["Data-ID"] == "42")
```

Positions are **1-based, inclusive byte indices into the original input**.
Element positions cover the start tag only, without inner content or the end
tag, and are unchanged by rewrites. Comment and DOCTYPE ranges include their
delimiters. For streaming input, positions are absolute across all writes;
extracting the original bytes requires retaining the corresponding input.

TextChunk and attribute source locations are not exposed.

## Execution and object lifetime

The parser is incremental, but **`write()` and `close()` are synchronous**. They
perform CPU work and call Lua handlers before returning. The module does not
fetch HTML, schedule background work, or provide asynchronous I/O. Processing a
large chunk occupies the calling thread until that call completes.

Content handlers and the sink must not yield, call yielding OpenResty APIs, or
recursively call `write()` or `close()` on the active rewriter. Perform I/O and
scheduling between writes, outside these callbacks.

Selectors can be reused. A builder can create multiple rewriters, but each
rewriter processes exactly one document. Register handlers and operate the
resulting rewriters in the same Lua thread/coroutine: callback registrations
retain the Lua state used to register them. Reusing a builder also reuses its
callback closures, so reset or separate any application state they capture.

Element, Comment, TextChunk, Doctype, and DocumentEnd objects are valid only
inside the callback that received them. Attribute iterators have the same
lifetime. Copy strings, numbers, or other Lua values out of a callback when they
are needed later; retaining a token object does not extend its validity. Using
an expired object raises a Lua error.

### Errors and stopping

Constructors and mutating operations that can fail return `nil, err`. Successful
mutations generally return `self`, allowing chaining. Invalid argument types and
expired token objects raise Lua errors instead.

Content handlers return nothing, `nil`, or `lolhtml.CONTINUE` to continue.
Returning `lolhtml.STOP` aborts processing and makes the current `write()` or
`close()` return `nil, err`; it is not a successful early EOF. Other return values
are invalid, including `true` or the token returned by a mutating method. Use
`assert(element:set_attribute(...))` inside a handler, without returning it.

If a handler or sink raises an error, the enclosing `write()` or `close()` returns
`nil` and the Lua error value. The error can be a table or another non-string
value, so use `tostring(err)` when logging it. A sink error disables further sink
calls; it does not guarantee an immediate stop of native processing within that
write.

## API reference

### Module functions and selectors

| Function | Result |
| --- | --- |
| `lolhtml.new_selector(css)` | Compiled Selector, or `nil, err` for invalid/unsupported syntax. |
| `lolhtml.new_rewriter_builder()` | New RewriterBuilder. |
| `lolhtml.new_rewriter(options)` | New Rewriter, or `nil, err`. |

Selector objects have no public methods. Pass a compiled Selector as the
`selector` field when registering element handlers, rather than a CSS string.
Supported syntax follows [lol-html's selector implementation][selectors].

### RewriterBuilder

`builder:add_document_content_handlers(handlers)` returns the builder. All fields
are optional and should be functions when provided:

| Field | Callback argument | When called |
| --- | --- | --- |
| `doctype_handler` | Doctype | A DOCTYPE declaration is parsed. |
| `comment_handler` | Comment | A comment anywhere in the document is parsed. |
| `text_handler` | TextChunk | A fragment of a text node is parsed. |
| `doc_end_handler` | DocumentEnd | The document is finalized by `close()`. |

`builder:add_element_content_handlers(handlers)` returns the builder or
`nil, err`. The `selector` field is required; handler fields are optional:

| Field | Value or callback argument | Scope |
| --- | --- | --- |
| `selector` | Selector | Selects the elements whose content is handled. |
| `element_handler` | Element | The matched element's start tag. |
| `comment_handler` | Comment | Comments inside matched elements, including descendants. |
| `text_handler` | TextChunk | Text inside matched elements, including descendants. |

Both registration methods can be called more than once. Omit unused handlers
instead of registering empty functions, so the parser can skip unnecessary work.
Complete registration before processing documents. The builder retains the
registered callbacks and selectors, and each rewriter retains its builder.

### Rewriter

Options for `lolhtml.new_rewriter(options)`:

| Field | Default | Meaning |
| --- | --- | --- |
| `builder` | Required | RewriterBuilder containing the handlers. |
| `sink` | `nil` | Function or callable object accepting an output string; omitted/nil discards output in C. |
| `encoding` | `"utf-8"` | Encoding of the input and output HTML byte streams. |
| `preallocated_parsing_buffer_size` | `1024` | Initial parser buffer capacity in bytes; `0` defers allocation. |
| `max_allowed_memory_usage` | `SIZE_MAX` | Limit for the native rewriter's accounted memory, in bytes. |
| `strict` | `false` | Abort when the parser cannot determine an unambiguous parsing context. |

The encoding must be a web-compatible encoding supported by lol-html; UTF-16LE,
UTF-16BE, ISO-2022-JP, and `replacement` are not supported. Text exposed to Lua
and strings supplied to mutation methods use UTF-8. The sink receives bytes in
the configured document encoding.

The memory limit is not an input size limit or a process memory limit. It does
not cover Lua output buffers, callback data, or the binding's attribute snapshots.
Exceeding it returns an error; automatic passthrough after a memory-limit failure
is not exposed. See the upstream [memory settings][lolhtml-memory] and
[strict parsing option][lolhtml-strict] for details.

| Method | Result and behavior |
| --- | --- |
| `rewriter:write(chunk)` | `self` or `nil, err`; process a string of input bytes. |
| `rewriter:close()` | `self` or `nil, err`; finish the document and release the native rewriter. |

`close()` takes no final chunk argument. Write any remaining bytes first. Calling
either method after a failure or successful close returns `nil, "broken rewriter"`.

### Element

Inspection and attribute methods:

| Method | Result |
| --- | --- |
| `get_tag_name(preserve_case)` | Tag name; ASCII lowercase by default, original/current case when `true`. |
| `set_tag_name(name)` | `self` or `nil, err`; rename the start tag and corresponding end tag. |
| `get_namespace_uri()` | Namespace URI string, such as `http://www.w3.org/1999/xhtml`. |
| `can_have_content()` | Boolean indicating whether the parsed element accepts inner content. |
| `is_self_closing()` | Boolean indicating whether the start tag used `/>` syntax. |
| `source_location()` | `first, last` input byte positions of the original start tag. |
| `get_attribute(name)` | Attribute value, or `nil` when absent. |
| `has_attribute(name)` | Boolean indicating whether the attribute exists. |
| `set_attribute(name, value)` | `self` or `nil, err`; add or change an attribute. |
| `remove_attribute(name)` | `self`; remove the attribute if present. |
| `attributes(preserve_case)` | Iterator triplet yielding attribute names and values. |

An existing boolean or explicitly empty attribute has the value `""`, not `nil`.
Attribute names yielded by the iterator are ASCII lowercase unless `true` is
passed. The iterator snapshots names and values when created: adding, removing,
or changing attributes during iteration does not alter that snapshot. It is
released on exhaustion, garbage collection, or callback exit. Prefer
`get_attribute()` when only a few known attributes are needed.

Tag renaming changes serialization, not the parser's namespace or content model.
Use it for compatible tags, such as `div` and `section`. In HTML, `<div/>` still
accepts content, while `<br>` does not. A self-closing SVG element does not accept
inner content. Use `can_have_content()` to decide whether inner insertion is
meaningful; `is_self_closing()` alone does not answer that question.

Content mutation methods use the [text/HTML rules](#rename-elements-and-change-their-content)
described above:

| Method | Effect |
| --- | --- |
| `before(content, is_html)` | Insert before the whole element. |
| `after(content, is_html)` | Insert after the whole element. |
| `prepend(content, is_html)` | Insert just inside the start tag. |
| `append(content, is_html)` | Insert just before the end tag. |
| `set_inner_content(content, is_html)` | Replace the element's inner content. |
| `replace(content, is_html)` | Replace the element and its contents. |
| `remove()` | Remove the element and its contents. |
| `remove_and_keep_content()` | Remove the surrounding element tags, keeping the contents. |
| `is_removed()` | Return a boolean indicating that the element was removed or replaced. |

Methods accepting content return `self` or `nil, err`. Removal methods return
`self`. Inner-content operations have no effect on elements that cannot have
content, such as HTML void elements.

### Comment

| Method | Result or effect |
| --- | --- |
| `get_text()` | Comment text without `<!--` and `-->`. |
| `set_text(text)` | `self` or `nil, err`; change comment text, rejecting text that would terminate the comment. |
| `before(content, is_html)` | Insert before the comment. |
| `after(content, is_html)` | Insert after the comment. |
| `replace(content, is_html)` | Replace the comment. |
| `remove()` | `self`; remove the comment. |
| `is_removed()` | Boolean; true after removal or replacement. |
| `source_location()` | `first, last` byte positions of the original comment, including delimiters. |

Insertion and replacement methods return `self` or `nil, err`.

### TextChunk

| Method | Result or effect |
| --- | --- |
| `get_text()` | UTF-8 text fragment, possibly empty; HTML character references are preserved. |
| `is_last_in_text_node()` | Boolean; marks the final fragment of this text node. |
| `before(content, is_html)` | Insert before this fragment. |
| `after(content, is_html)` | Insert after this fragment. |
| `replace(content, is_html)` | Replace this fragment, not the entire text node. |
| `remove()` | `self`; remove this fragment. |
| `is_removed()` | Boolean; true after removal or replacement. |

Insertion and replacement methods return `self` or `nil, err`. See the
[extraction example](#extract-links-and-a-title-without-producing-html) for
fragment boundaries and accumulation.

### Doctype

| Method | Result or effect |
| --- | --- |
| `get_name()` | Lowercase name, or `nil` if absent. |
| `get_id()` | Public identifier, or `nil` if absent. |
| `get_system_id()` | System identifier, or `nil` if absent. |
| `remove()` | `self`; omit this DOCTYPE declaration from output. |
| `is_removed()` | Boolean indicating whether it was removed. |
| `source_location()` | `first, last` byte positions of the original declaration. |

Removal is idempotent. Original source positions remain available during the
callback even after removal.

### DocumentEnd

`doc_end:append(content, is_html)` appends text or HTML at EOF and returns `self`
or `nil, err`. This object is provided to `doc_end_handler` during `close()`.

## OpenResty

Use a builder, rewriter, and result buffers local to the request and its Lua
coroutine. Do not cache a builder with registered handlers in a module shared
across requests. Loading the `lolhtml` module itself through `require` is fine.

For example, place this location in an existing `server` block:

```nginx
location = /rewrite-demo {
    default_type text/html;

    content_by_lua_block {
        local lolhtml = require "lolhtml"
        local output = {}
        local builder = lolhtml.new_rewriter_builder()

        assert(builder:add_element_content_handlers {
            selector = assert(lolhtml.new_selector("h1")),
            element_handler = function(element)
                assert(element:set_tag_name("h2"))
            end,
        })

        local rewriter = assert(lolhtml.new_rewriter {
            builder = builder,
            sink = function(chunk) output[#output + 1] = chunk end,
        })
        assert(rewriter:write("<h1>Hello from OpenResty</h1>"))
        assert(rewriter:close())
        ngx.print(table.concat(output))
    }
}
```

The sink only collects strings; response output happens after the native call
returns. For a streaming source, read input and drain accumulated output between
`write()` calls, keeping any yielding I/O outside the handlers and sink. Bound
application buffers as well as native parser memory.

HTTP integration remains the caller's responsibility: feed decoded HTML rather
than compressed response bytes, and update or remove an existing `Content-Length`
when rewriting changes the body length. The module does not modify HTTP headers.

## Development and tests

From a checkout with submodules initialized, install the LuaJIT build dependencies
listed above and clone the test runner:

```sh
mkdir -p .ci
git clone https://github.com/jdesgats/telescope.git .ci/telescope
bash util/run-tests.sh
```

The script builds the binding and runs `spec/lolhtml.lua` with the local `.so`.
It expects the Debian/Ubuntu LuaJIT header location. To run the suite against a
module installed by LuaRocks instead:

```sh
LUA_PATH="$PWD/.ci/telescope/?.lua;;" \
LUA_CPATH="/path/to/rock-tree/lib/lua/5.1/?.so" \
  luajit .ci/telescope/tsc spec/lolhtml.lua
```

GitHub Actions tests direct builds and LuaRocks installation with Rust 1.89 and
stable. A numeric release tag, such as `1.1.0`, additionally packs the matching
rockspec, installs and tests the source rock, then publishes it to LuaRocks.

The suite covers handler dispatch, output/error propagation, callback lifetimes,
chunked parsing, empty attributes, safe attribute iteration, token mutations,
source positions, and native memory-limit regressions. Additional small scripts
are available in [examples/](examples/).

## License

BSD-3-Clause; see [LICENSE](LICENSE). The bundled native dependencies retain their
own licenses.

[lolhtml]: https://github.com/cloudflare/lol-html
[lolhtml-memory]: https://docs.rs/lol_html/3.0.3/lol_html/struct.MemorySettings.html
[lolhtml-strict]: https://docs.rs/lol_html/3.0.3/lol_html/struct.Settings.html#structfield.strict
[selectors]: https://docs.rs/lol_html/3.0.3/lol_html/struct.Selector.html
[rust-install]: https://www.rust-lang.org/tools/install
