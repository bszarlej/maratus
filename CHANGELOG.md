# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

## 2026-11-10

### Changes

---

Packages with breaking changes:

 - [`maratus` - `v0.2.0`](#maratus---v020)

Packages with other changes:

 - [`maratus_annotations` - `v0.1.2`](#maratus_annotations---v012)
 - [`maratus_generator` - `v0.1.2`](#maratus_generator---v012)
 - [`maratus_flame` - `v0.1.3`](#maratus_flame---v013)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `maratus_flame` - `v0.1.3`

---

#### `maratus` - `v0.2.0`

 - **FEAT**: send RPCs and fields with their delivery settings. ([ce4ae28d](https://github.com/bszarlej/maratus/commit/ce4ae28d723ee5557650913c317a18505b06c8e5))
 - **FEAT**: add unreliable delivery and channels to the in-memory network. ([4412c2aa](https://github.com/bszarlej/maratus/commit/4412c2aaa5e9c75b83c9dbc9f0421e948f486dc5))
 - **DOCS**: describe delivery modes and channels. ([f9b3032e](https://github.com/bszarlej/maratus/commit/f9b3032e993ee76adb6941ef566fad3057b4ba6b))
 - **BREAKING** **FEAT**: add delivery settings to RPC and field handles. ([d97a380e](https://github.com/bszarlej/maratus/commit/d97a380e2ea3df1f7c3a317060eda0ce1cde332b))

#### `maratus_annotations` - `v0.1.2`

 - **FEAT**: add delivery settings to RpcMethod and SyncedField. ([efae4be0](https://github.com/bszarlej/maratus/commit/efae4be0d9033444213a5e60ed8866023ac9a55b))
 - **DOCS**: list the delivery settings of RpcMethod and SyncedField. ([85e7a93a](https://github.com/bszarlej/maratus/commit/85e7a93acd5760f5198b2c2af1fc5ddd12a07ea2))

#### `maratus_generator` - `v0.1.2`

 - **FEAT**: generate delivery settings for RPCs and fields. ([91d1c66e](https://github.com/bszarlej/maratus/commit/91d1c66e45db1644d0cb39d0768bbbc9cf4e6d2d))
 - **DOCS**: describe delivery settings in annotations. ([fc7d661c](https://github.com/bszarlej/maratus/commit/fc7d661c3ea70e43d783c49ff7d370ea6905c0d6))


## 2026-11-10

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`maratus` - `v0.1.2`](#maratus---v012)
 - [`maratus_annotations` - `v0.1.1`](#maratus_annotations---v011)
 - [`maratus_flame` - `v0.1.2`](#maratus_flame---v012)
 - [`maratus_generator` - `v0.1.1`](#maratus_generator---v011)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `maratus_annotations` - `v0.1.1`
 - `maratus_flame` - `v0.1.2`
 - `maratus_generator` - `v0.1.1`

---

#### `maratus` - `v0.1.2`

 - **FEAT**: replicate session membership to clients. ([70904a7e](https://github.com/bszarlej/maratus/commit/70904a7edba8924d8e5a3a84999d06c31d9297fc))
 - **FEAT**: add membership messages to the protocol. ([2f7d7cf9](https://github.com/bszarlej/maratus/commit/2f7d7cf920c4e1253f48c507161f9064a23bf357))
 - **FEAT**: return the authority of departed clients to the host. ([82b55aaa](https://github.com/bszarlej/maratus/commit/82b55aaa161d0106bb04a40aee22356d3a666350))
 - **FEAT**: switch synchronizer roles on authority transfers. ([1468262e](https://github.com/bszarlej/maratus/commit/1468262eefb35ead5195c0de21962d95de5ee04f))
 - **FEAT**: transfer entity authority at runtime. ([e6e6f023](https://github.com/bszarlej/maratus/commit/e6e6f0238acc9073de459d1223aabab7d78cdbbd))
 - **FEAT**: add authority transfer messages to the protocol. ([b71e2bcd](https://github.com/bszarlej/maratus/commit/b71e2bcde65af77f0d930aa25a5292a9b4bb0c71))
 - **DOCS**: describe player membership on clients. ([f6fca075](https://github.com/bszarlej/maratus/commit/f6fca07549d4d1b8b706ee1f53d42307aaf2d911))
 - **DOCS**: describe authority transfers and their guarantees. ([882f7860](https://github.com/bszarlej/maratus/commit/882f7860d234bdaadd979bf1c6e3a04c91daedd2))


## 2026-11-09

### Changes

---

Packages with breaking changes:

 - There are no breaking changes in this release.

Packages with other changes:

 - [`maratus` - `v0.1.1`](#maratus---v011)
 - [`maratus_annotations` - `v0.1.1`](#maratus_annotations---v011)
 - [`maratus_flame` - `v0.1.1`](#maratus_flame---v011)
 - [`maratus_generator` - `v0.1.1`](#maratus_generator---v011)

---

#### `maratus` - `v0.1.1`

 - **FEAT**(maratus): add WireList for list-shaped wire values.
 - **FEAT**(maratus): register existing handles with the schema builder.
 - **DOCS**(maratus): show registering a schema by hand and with annotations.

#### `maratus_annotations` - `v0.1.1`

 - **FEAT**(maratus_annotations): add annotations for code generation.

#### `maratus_flame` - `v0.1.1`

 - **FEAT**(maratus_flame): bind generated members before onNetworkAttach.
 - **DOCS**(maratus_flame): mention components annotated for code generation.

#### `maratus_generator` - `v0.1.1`

 - **FIX**(maratus_generator): support analyzer 8.4 and 9.
 - **FEAT**(maratus_generator): add the code generator.
 - **DOCS**(maratus_generator): name a readable field in the synchronizer documentation.

