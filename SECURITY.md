# Security Policy

## Scope

This repository contains shell/PowerShell setup scripts and documentation. The scripts:

- install `agy` using Google's official installer (only if `agy` is missing),
- merge allow/deny rules and a trusted workspace into `~/.gemini/antigravity-cli/settings.json`,
- append delegation rules to the `CLAUDE.md` of the directory they are run in.

Security-relevant issues include, for example: a default rule that grants `agy` broader access than documented (such as writes outside the project directory, or reading `.env`), a script bug that overwrites or corrupts existing settings, or a way for untrusted input to alter what the scripts execute.

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private reporting: open the **Security** tab of this repository and choose **Report a vulnerability**. Include the affected file, the steps to reproduce, and the impact you observed.

I aim to acknowledge reports within 7 days. This is a small, single-maintainer project, so fixes are best-effort.

## Supported versions

Only the latest commit on `main` is supported. Projects that ran an older `setup.sh` / `setup.ps1` keep the older `CLAUDE.md` rules; see README Q5 for how to upgrade.

## Not in scope

- Vulnerabilities in `agy`, Antigravity, or Claude Code themselves; report those to Google or Anthropic.
- Risks that are already documented, such as piping a remote script into your shell (`curl | bash`), or opting in to broader rules like `cat`, `rg`, or `pytest` in your own `settings.json`.
