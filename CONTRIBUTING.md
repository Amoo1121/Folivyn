# Contributing to Folivyn

Folivyn is a personal project under active development. Bug reports, suggestions, focused pull requests, and translation improvements are welcome.

## Code and asset provenance

- Submit only work you have the right to contribute under the project's [MIT license](LICENSE).
- Implement behavior independently from requirements, public standards, and documented system APIs. Do not copy or lightly rewrite another project's implementation, tutorial code, or an unlicensed snippet.
- The current implementation uses macOS system frameworks and has no third-party package dependencies or bundled third-party assets. Keep this scope for routine changes.
- For any proposed third-party component, code, grammar, theme, font, image, or fixture, document its upstream URL, exact version, applicable license, required notices, and intended use before integration. Public availability alone is not permission to reuse it. Do not add material whose source or rights are unclear.
- Preserve existing copyright and license notices. Do not relabel third-party work as original Folivyn code.
- Review AI-assisted contributions for correctness and identifiable external sources using the same rules as other code. AI generation is not proof of originality or permission.
- Include relevant source references and a brief provenance explanation with a pull request when external material informed the implementation. A documentation reference does not authorize copying its examples.

These contribution requirements govern what this repository accepts; they do not add restrictions to the MIT license granted to recipients.

## Validation

Describe the behavior changed and how it was checked. For Swift changes, follow the test and build commands in the [README](README.md). Use small, non-sensitive examples for file-handling bugs.

The [source provenance review](docs/source-provenance-review.md) records the scope and limitations of the initial repository audit.
