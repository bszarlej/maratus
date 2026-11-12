<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-dark.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg">
    <img src="https://raw.githubusercontent.com/bszarlej/maratus/master/assets/maratus-lockup-on-light.svg" alt="Maratus logo" width="300">
  </picture>
</p>

# maratus_annotations

Annotations for declaring RPC handlers, synchronized fields, spawn types, and
value codecs in [maratus](https://pub.dev/packages/maratus). Use with
[`maratus_generator`](https://pub.dev/packages/maratus_generator) to generate
protocol registration and entity bindings. Both packages work with pure Dart;
Flame components also receive typed RPC senders.

## Installation

```sh
dart pub add maratus maratus_annotations dev:maratus_generator dev:build_runner
```

For a Flame project:

```sh
flutter pub add maratus_flame maratus_annotations dev:maratus_generator dev:build_runner
```

Follow the [generator setup and example](https://pub.dev/packages/maratus_generator)
to add a generated part, register the protocol, and bind entities.

## Annotations

| Annotation | On | Declares |
| ---------- | -- | -------- |
| `@Networked` | Class | Protocol handles and bindings; optional spawn type and synchronization timing. |
| `@RpcMethod` | Method | RPC identifier, caller permissions, routing, and delivery settings. |
| `@SyncedField` | Field or getter | Field identifier, sampling, delivery, and optional interpolation. |
| `@NetworkCodec` | Class | A `ValueCodec` with an explicit descriptor. |
| `@WireKey` | Field | A stable key in a generated data codec. |
| `@Range` | Parameter, field, or getter | Inclusive numeric bounds. |
| `@MaxLength` | Parameter, field, or getter | Maximum string or list length. |
| `@UseCodec` | Parameter, field, or getter | A custom const codec for the declared type. |

RPCs default to any caller, the host target, no local execution, and reliable
delivery on channel zero. Synchronized fields default to `SyncMode.onChange`
with reliable delivery on channel zero. Set caller permissions explicitly when
an RPC should be restricted to an entity's owner, authority, or the host.

Built-in codecs cover `bool`, `int`, `double`, `String`, lists, and nullable
types. Strings and lists default to a maximum length of 256. Other types need
`@NetworkCodec` or `@UseCodec`; a custom codec cannot be combined with `@Range`
or `@MaxLength` on the same value.

## License

MIT. See [LICENSE](LICENSE).
