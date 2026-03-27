# Namu Markdown Skill

This skill helps Claude Code work with markdown content in terminal panes.

## Rendering markdown in a terminal pane

Namu's terminal supports rich rendering. To display markdown:

```bash
# Using glow (if installed)
echo "# Hello" | glow -

# Using bat with markdown syntax highlighting
bat --language markdown file.md

# Using pandoc to convert to plain text
pandoc -t plain file.md
```

## Sending formatted content to a pane

```bash
# Send a multi-line string to the focused pane
namu pane send_keys "cat <<'EOF'\n# Heading\n\n- item 1\n- item 2\nEOF\n"
```

## Reading pane output for markdown processing

```bash
# Read current pane content and process with Claude
namu pane read_screen --json | jq -r '.result.text'
```

## Tips

- Namu terminal panes support OSC-8 hyperlinks (clickable links in terminal)
- Images dropped onto a pane are rendered via Kitty graphics protocol
- SSH panes auto-detect remote connections for file transfer
