<picture>
  <source media="(prefers-color-scheme: dark)" srcset="../../assets/maratus-mark-on-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="../../assets/maratus-mark-on-light.svg">
  <img src="../../assets/maratus-mark-on-light.svg" alt="Maratus logo" width="80">
</picture>

# Visibility example

A host and a client run side by side in one Flame game, joined by an in-memory
network. The host spawns a grid of crates and a player for the client, which
steers it with the arrow keys. A visibility filter on the host shows the client
only the crates near its player, so the client receives the other crates
neither when it joins nor afterwards.

Requires Dart `>=3.11.0 <4.0.0` and Flutter `>=3.41.0`. Use Chrome for the web
runner or install Flutter's Windows build tools for the desktop runner.

## Run

From the repository root:

```sh
flutter pub get
cd examples/visibility
flutter run -d chrome
```

Or run `flutter run -d windows`. On macOS or Linux, generate the corresponding
runner first with `flutter create --platforms=macos .` or
`flutter create --platforms=linux .`.

## Try it

- Hold an arrow key. The host's view shows every crate; the client's view shows
  only those inside its player's circle. Crates come into the client's view as
  the player approaches them and leave it as the player moves away.
- Watch the host's view: it dims the crates that no client sees.

## Explore the code

- [arena.dart](lib/arena.dart): the player and the crates. Their spawn types
  and the player's position, an owner-written field that the client that owns
  the player writes, are generated from their annotations into the shared
  schema. The host applies the position interpolated, 40 ms behind the newest
  sample, so the player moves smoothly in its view, and its visibility rules
  see the position that it shows.
- [main.dart](lib/main.dart): the host and the client, their views, and the
  host's `ProximityRules`. They spawn the crates and the player, add the
  visibility filter, and run it again with `updateVisibility` five times a
  second, as the player moves.

After changing the annotations, regenerate `arena.g.dart`:

```sh
dart run build_runner build
```

Visibility is the host's decision at runtime, not part of the schema, so it
has no annotations. The filter shows a crate inside `showRange` of the client's player and hides it
again only beyond `hideRange`, so crates at the edge do not keep leaving and
returning. The client always sees its own player, which it owns.

See the core [visibility guide](../../packages/maratus/README.md#visibility) for
how the host decides what each client sees.
