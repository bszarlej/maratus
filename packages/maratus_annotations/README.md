<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

<p align="center">
  Annotations for generating <a href="https://pub.dev/packages/maratus">maratus</a> multiplayer code.
</p>

---

# maratus_annotations

Declare a class's RPC handlers, synchronized fields, and spawn type, or a data
class's codec, with annotations.
[`maratus_generator`](https://pub.dev/packages/maratus_generator) turns them
into the handles, codecs, and schema fingerprint that hand-written registration
produces, plus the code that binds and calls them.

## Install

```sh
dart pub add maratus_annotations dev:maratus_generator dev:build_runner
```

Use `flutter pub add` with the same arguments in a Flutter project.

## Annotations

| Annotation | On | Declares |
| ---------- | -- | -------- |
| `@Networked` | class | Generated handles, their registration, a binding mixin, and typed RPC senders; optionally the class's spawn type. |
| `@RpcMethod` | method | The RPC that the method handles, with its caller, target, and local policies. |
| `@SyncedField` | field or getter | A synchronized field. |
| `@NetworkCodec` | class | A generated `ValueCodec` for the class. |
| `@WireKey` | field | The wire key of a field in a generated codec. |
| `@Range`, `@MaxLength`, `@UseCodec` | parameter, field, or getter | The codec of a value. |

The [`maratus_generator` README](https://pub.dev/packages/maratus_generator)
shows how to use them.

## License

MIT. See [LICENSE](LICENSE).
