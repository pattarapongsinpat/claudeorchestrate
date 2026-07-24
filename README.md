# Claude Orchestrate

Global autonomous implementation workflow for Claude Code. Claude orchestrates intent, review, and verification. DeepSeek generates plans, tests, and implementation steps.

## Requirements

- Claude Code
- Git and Bash
- `jq`, `curl`, and `rg`
- A DeepSeek API key

Install the native toolchain used by your projects:

| Projects | Required tools |
|---|---|
| Python | Python and pytest |
| JavaScript or TypeScript | Node.js and the project's package manager |
| Go | Go |
| Rust | Rust and Cargo |
| Java | A JDK and Maven or Gradle |
| C# | .NET SDK |
| C or C++ | CMake, Meson, or Make plus a compiler |

## Windows installation

```powershell
git clone https://github.com/pattarapongsinpat/claudeochestrate.git "$HOME\.claudeochestrate"
Set-Location "$HOME\.claudeochestrate"
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

## macOS or Linux installation

```bash
git clone https://github.com/pattarapongsinpat/claudeochestrate.git ~/.claudeochestrate
cd ~/.claudeochestrate
bash install.sh
```

Set the key in `~/.claudeochestrate/.env`:

```text
DEEPSEEK_API_KEY=your-key
```

Restart Claude Code. Ask for a code change normally. Claude can invoke the build skill automatically. Use `/build <request>` to invoke it explicitly.

Supported languages are Python, JavaScript, TypeScript, Go, Rust, Java, C#,
C, and C++. C and C++ use the project's existing native test suite. C# needs
an existing test project.

## Update

```bash
cd ~/.claudeochestrate
git pull
```

Rerun the installer after command or skill changes.
