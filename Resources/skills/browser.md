# Namu Browser Skill

This skill gives Claude Code access to the embedded browser panel in Namu.

## Available Commands

```bash
# Navigate to a URL
namu browser navigate --url "https://example.com"

# Go back / forward
namu browser back
namu browser forward

# Reload the page
namu browser reload

# Get the current URL
namu browser get_url

# Get page title
namu browser get_title

# Execute JavaScript and get the result
namu browser execute_js --script "document.title"

# Click an element by CSS selector
namu browser click --selector "#submit-button"

# Type text into an element
namu browser type --selector "#search-input" --text "hello world"

# Hover over an element
namu browser hover --selector ".nav-item"

# Get text content of an element
namu browser get_text --selector "h1"

# Get an attribute value
namu browser get_attribute --selector "a.link" --attribute "href"

# Take a screenshot (returns base64 PNG)
namu browser screenshot

# Target a specific browser pane
namu browser navigate --surface_id <uuid> --url "https://example.com"
```

## Tips

- The browser panel is embedded (WKWebView)
- JavaScript execution returns the result as a string
- Screenshots return base64-encoded PNG data
- Use `--json` for structured output
- Use `--surface_id <uuid>` to target a specific browser pane when multiple are open
