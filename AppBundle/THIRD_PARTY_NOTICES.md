# Third-party notices

PermanentUnderclass depends on the packages below. Exact license and notice
texts are distributed in `ThirdPartyLicenses/`, preserving their upstream file
names and paths. The bundled texts control if this summary differs from them.

| Package | Version | License | Source |
| --- | --- | --- | --- |
| Argmax OSS Swift | 1.0.0 | MIT | https://github.com/argmaxinc/argmax-oss-swift |
| AsyncHTTPClient | 1.36.0 | Apache-2.0 | https://github.com/swift-server/async-http-client |
| FluidAudio | 0.15.4 | Apache-2.0 | https://github.com/FluidInference/FluidAudio |
| Hummingbird | 2.22.0 | Apache-2.0 | https://github.com/hummingbird-project/hummingbird |
| Swift Algorithms | 1.2.1 | Apache-2.0 | https://github.com/apple/swift-algorithms |
| Swift Argument Parser | 1.8.2 | Apache-2.0 | https://github.com/apple/swift-argument-parser |
| Swift ASN.1 | 1.7.1 | Apache-2.0 | https://github.com/apple/swift-asn1 |
| Swift Async Algorithms | 1.1.5 | Apache-2.0 | https://github.com/apple/swift-async-algorithms |
| Swift Atomics | 1.3.1 | Apache-2.0 | https://github.com/apple/swift-atomics |
| Swift Certificates | 1.19.4 | Apache-2.0 | https://github.com/apple/swift-certificates |
| Swift Collections | 1.6.0 | Apache-2.0 | https://github.com/apple/swift-collections |
| Swift Configuration | 1.2.0 | Apache-2.0 | https://github.com/apple/swift-configuration |
| Swift Crypto | 4.5.1 | Apache-2.0 | https://github.com/apple/swift-crypto |
| Swift Distributed Tracing | 1.4.1 | Apache-2.0 | https://github.com/apple/swift-distributed-tracing |
| Swift HTTP Structured Headers | 1.7.0 | Apache-2.0 | https://github.com/apple/swift-http-structured-headers |
| Swift HTTP Types | 1.6.0 | Apache-2.0 | https://github.com/apple/swift-http-types |
| Swift Log | 1.14.0 | Apache-2.0 | https://github.com/apple/swift-log |
| Swift Metrics | 2.11.0 | Apache-2.0 | https://github.com/apple/swift-metrics |
| SwiftNIO | 2.101.3 | Apache-2.0 | https://github.com/apple/swift-nio |
| SwiftNIO Extras | 1.34.3 | Apache-2.0 | https://github.com/apple/swift-nio-extras |
| SwiftNIO HTTP/2 | 1.45.0 | Apache-2.0 | https://github.com/apple/swift-nio-http2 |
| SwiftNIO SSL | 2.37.2 | Apache-2.0 | https://github.com/apple/swift-nio-ssl |
| SwiftNIO Transport Services | 1.28.0 | Apache-2.0 | https://github.com/apple/swift-nio-transport-services |
| Swift Numerics | 1.1.1 | Apache-2.0 | https://github.com/apple/swift-numerics |
| Swift Service Context | 1.3.0 | Apache-2.0 | https://github.com/apple/swift-service-context |
| Swift Service Lifecycle | 2.11.0 | Apache-2.0 | https://github.com/swift-server/swift-service-lifecycle |
| Swift System | 1.7.5 | Apache-2.0 | https://github.com/apple/swift-system |

## Separately downloaded models

The model files below are downloaded on demand and are not stored in this
repository or bundled in the application.

### OpenAI Whisper Large v3

The optional local transcription engine downloads an Argmax Core ML conversion
of OpenAI Whisper Large v3. OpenAI Whisper is Copyright 2022 OpenAI and is
available under the MIT License.

- Original model and implementation: https://github.com/openai/whisper
- Core ML conversion: https://huggingface.co/argmaxinc/whisperkit-coreml

### NVIDIA Parakeet TDT 0.6B v3

The optional local transcription engine uses NVIDIA Parakeet TDT 0.6B v3,
converted to Core ML by FluidInference.

- Original model: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Core ML conversion: https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- Copyright and attribution: NVIDIA Corporation
