# AparteSecrets for Swift

[![test](https://github.com/apartejs/aparte-secrets-swift/actions/workflows/test.yml/badge.svg)](https://github.com/apartejs/aparte-secrets-swift/actions/workflows/test.yml)

Finds passwords, API keys, tokens and private keys in text, on the device — the [aparte-secrets](https://huggingface.co/apartejs/aparte-secrets) model (196 KB, int8) bundled, offline, no dependency but Foundation.

```swift
import AparteSecrets

let secrets = try Secrets.load()   // load once, share across threads
secrets.detect("the wifi password is Sunflower77# for the guests")
// [Span(21..<33, text: "Sunflower77#", subtype: password, score: …)]

let masked = secrets.mask(message)                       // "[PASSWORD_1]" instead of the value
let answer = try await askTheModel(masked.text)           // the secret never leaves the device
secrets.unmask(answer, secrets: masked.secrets)           // the values back, locally
```

- Also for JavaScript: [`@aparte/secrets`](https://www.npmjs.com/package/@aparte/secrets) and the CLI [`@aparte/secrets-cli`](https://www.npmjs.com/package/@aparte/secrets-cli) on npm; for Android and the JVM: [aparte-secrets-kotlin](https://github.com/apartejs/aparte-secrets-kotlin)
- Model, scores and limits: [huggingface.co/apartejs/aparte-secrets](https://huggingface.co/apartejs/aparte-secrets)

## Install

Swift Package Manager. In Xcode: *File → Add Package Dependencies…* and paste the repository URL. In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/apartejs/aparte-secrets-swift.git", from: "1.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "AparteSecrets", package: "aparte-secrets-swift"),
    ]),
]
```

iOS 13, macOS 10.15, tvOS 13, watchOS 6, visionOS 1, and Linux and Windows.

## Use

Each `Span` has its `text`, its `subtype` (`password`, `api_key`, `token`, `private_key` or `other`), a `score` from 0 to 1, its `range` in the string (`text[span.range]`) and its `utf16Range`, the offsets the JavaScript and Kotlin runtimes report.

The model reports raw spans; `minScore`, `ignore` (exact values) and `ignorePatterns` (regular expressions) are your policy, applied after it:

```swift
secrets.detect(text, minScore: 0.5, ignore: ["changeme"])
```

A value found once is masked everywhere it appears. Any other model file of [the Hugging Face repository](https://huggingface.co/apartejs/aparte-secrets) loads with `Secrets(contentsOf: url)`.

## How good

On a chat test written after training (440 messages, English and French), strict span F1 **0.76** (OpenAI privacy-filter 0.53, detect-secrets 0.27, gitleaks 0.29). Every number, and the limits: [the model card](https://huggingface.co/apartejs/aparte-secrets).

## Same spans everywhere

It is the same runtime as the JavaScript package and gives the same spans as the Python reference implementation: the tests compare every span of the 2,660 reference texts (same text, same subtype, score within 2e-4), on macOS, Linux, Windows and the iPhone simulator.

```bash
swift test -c release                                                # API tests
APARTE_SECRETS_REFS=references_int8.jsonl swift test -c release      # + equality with the reference spans
```

`references_int8.jsonl` is on [Hugging Face](https://huggingface.co/apartejs/aparte-secrets/tree/main/references): it holds secret-shaped strings, so it is not in this repository.

## Versions

All aparte-secrets packages share one version, `<model version>.<package fix>`: 1.1.x carries model v1.1.

## License

MIT, Copyright (c) 2026 Paul Richez.
