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

On Windows, the integration launches Git Bash explicitly through
`pipeline/invoke.ps1`. It does not depend on the `bash` command in `PATH`, which
may otherwise launch WSL.

Supported languages are Python, JavaScript, TypeScript, Go, Rust, Java, C#,
C, and C++. C and C++ use the project's existing native test suite. C# needs
an existing test project.

## Pipeline tests

On Windows, run the installed-toolchain smoke suite with:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 smoke_adapters
```

Run against a project without changing the caller's working directory:

```powershell
powershell -ExecutionPolicy Bypass -File "$HOME\.claudeochestrate\pipeline\invoke.ps1" run -Repo "C:\path\to\project"
```

Test Maven without installing Java system-wide with:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_java.ps1
```

Run real DeepSeek implementation loops for compiled languages:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_java.ps1 -E2E
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_compiled csharp
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_compiled c
powershell -ExecutionPolicy Bypass -File .\pipeline\invoke.ps1 test_e2e_compiled cpp
```

Test the Make adapter without installation or UAC with:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_make.ps1
```

The Java runner verifies downloaded JDK and Maven checksums and removes its
temporary toolchain after the suite finishes.

Run every supported Windows adapter with temporary checksum-verified toolchains:

```powershell
powershell -ExecutionPolicy Bypass -File .\pipeline\test_all_toolchains.ps1
```

## Update

```bash
cd ~/.claudeochestrate
git pull
```

Rerun the installer after command or skill changes.
