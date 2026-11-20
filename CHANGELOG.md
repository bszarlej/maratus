# Change Log

All notable changes to this project will be documented in this file.
See [Conventional Commits](https://conventionalcommits.org) for commit guidelines.

## 2026-11-20

### Changes

---

Packages with breaking changes:

 - [`maratus` - `v0.4.0`](#maratus---v040)

Packages with other changes:

 - [`maratus_annotations` - `v0.1.4`](#maratus_annotations---v014)
 - [`maratus_flame` - `v0.1.5`](#maratus_flame---v015)
 - [`maratus_generator` - `v0.1.4`](#maratus_generator---v014)
 - [`maratus_enet` - `v0.1.2`](#maratus_enet---v012)
 - [`maratus_webrtc` - `v0.1.2`](#maratus_webrtc---v012)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `maratus_enet` - `v0.1.2`
 - `maratus_webrtc` - `v0.1.2`

---

#### `maratus` - `v0.4.0`

 - **REFACTOR**: rename Prediction to Predictor. ([7a9dd933](https://github.com/bszarlej/maratus/commit/7a9dd9335bdd0b4d645913c1ffc29f05cbba184e))
 - **FEAT**: run a prediction's frame on every peer with update. ([d6de01a2](https://github.com/bszarlej/maratus/commit/d6de01a251bfadeef21a4c8daac647fce59058cf))
 - **FEAT**: add name-based enum codec. ([0d2b4e28](https://github.com/bszarlej/maratus/commit/0d2b4e281385c2b63e4fa7c856f4c0bd4c66b6d8))
 - **FEAT**: keep predicted entities moving while inputs are late. ([972aa08d](https://github.com/bszarlej/maratus/commit/972aa08d7eb2409dbae0905e93275c1ad9b5c957))
 - **FEAT**: let the authority set the state of a prediction. ([24e53d41](https://github.com/bszarlej/maratus/commit/24e53d41b66ba15874e1370b2536d32d3caae22a))
 - **FEAT**: predict owner-controlled entities. ([46e0a568](https://github.com/bszarlej/maratus/commit/46e0a568429ff33b795f86b73299a68506f1e356))
 - **FEAT**: add input streams to the schema. ([b1184b44](https://github.com/bszarlej/maratus/commit/b1184b44a8bac397cbd90308dc64bfd58c4838c8))
 - **DOCS**: point Flame games to proximity visibility. ([eb116c55](https://github.com/bszarlej/maratus/commit/eb116c555187b9330b05c254c18467c22b4710b3))
 - **DOCS**: describe setters of interpolated properties. ([a600108c](https://github.com/bszarlej/maratus/commit/a600108cec87de2414d72916748f2d0e335049b1))
 - **DOCS**: link predictions declared with annotations. ([a8480b25](https://github.com/bszarlej/maratus/commit/a8480b25ee255517af1d3c43e6573a467e0a7d92))
 - **DOCS**: describe entity visibility. ([56dccde4](https://github.com/bszarlej/maratus/commit/56dccde43252b31c970f740330ee997ebeddb8e3))
 - **DOCS**: describe client-side prediction. ([5e516a77](https://github.com/bszarlej/maratus/commit/5e516a77746f3010d10832a2b915463db6ea72ba))
 - **DOCS**: add pub version and CI badges [skip ci]. ([585daf71](https://github.com/bszarlej/maratus/commit/585daf71f38cde4010786a4c4089a73591d4aaad))
 - **DOCS**: correct package documentation. ([fe51ec67](https://github.com/bszarlej/maratus/commit/fe51ec67ca3e12de89bb15c2efe1dca9386b2bf3))
 - **BREAKING** **FEAT**: pass interpolated values to setters. ([f91ad2d6](https://github.com/bszarlej/maratus/commit/f91ad2d6eb28ac0d14ac2b0ef00cd69020b05335))
 - **BREAKING** **FEAT**: replicate entities only to the clients that see them. ([78fdcb62](https://github.com/bszarlej/maratus/commit/78fdcb62e1367ad16ab5726a0c349f3d70d1bbf2))
 - **BREAKING** **FEAT**: add shown spawn records to the protocol. ([7cc87736](https://github.com/bszarlej/maratus/commit/7cc87736b847771ece4f4617790f2a7880c7c3df))
 - **BREAKING** **FEAT**: add input messages and applied inputs to state. ([4eea8014](https://github.com/bszarlej/maratus/commit/4eea8014b6f0599c95bfee20b14c209bb17ec00c))
 - **BREAKING** **FEAT**: add owner-written synchronized fields. ([e6a17e8f](https://github.com/bszarlej/maratus/commit/e6a17e8f163a36b4b2da8febec08bb420f4faffc))

#### `maratus_annotations` - `v0.1.4`

 - **FEAT**: add SyncedField.applyInterpolated. ([670a89d2](https://github.com/bszarlej/maratus/commit/670a89d2446845cb35eced0c5cae7e83eddee3ef))
 - **FEAT**: add Prediction. ([6e975c31](https://github.com/bszarlej/maratus/commit/6e975c3113c6eead2611395f5899b828927f6b6d))
 - **FEAT**: add a writer to SyncedField. ([c5fde3c8](https://github.com/bszarlej/maratus/commit/c5fde3c8d15ea72ae8b0b69845530050b87babc9))
 - **DOCS**: add pub version and CI badges [skip ci]. ([585daf71](https://github.com/bszarlej/maratus/commit/585daf71f38cde4010786a4c4089a73591d4aaad))
 - **DOCS**: clarify annotation documentation. ([37c2b853](https://github.com/bszarlej/maratus/commit/37c2b853ddecbcc7a8137361e2353619b1b8861b))

#### `maratus_flame` - `v0.1.5`

 - **FEAT**: add a proximity visibility component. ([52cb1587](https://github.com/bszarlej/maratus/commit/52cb158718232a96dd3673c59184666e8c57edac))
 - **FEAT**: update generated members every frame. ([e19177b8](https://github.com/bszarlej/maratus/commit/e19177b891d6d09300ef4eabcc0f5fd22caff703))
 - **FEAT**: look up the components that a peer owns. ([4146b159](https://github.com/bszarlej/maratus/commit/4146b159a7e4090c476cccfed87304284df1a714))
 - **FEAT**: pass session events to a scope callback. ([ed4ed0be](https://github.com/bszarlej/maratus/commit/ed4ed0be242b01b6f2d8c3cc9bf9435575057c0e))
 - **FEAT**: add isNetworkOwner and isNetworkAuthority. ([eab5ddf3](https://github.com/bszarlej/maratus/commit/eab5ddf36a7d0cc5c1f69ff9becbd0611d937b55))
 - **DOCS**: describe proximity visibility. ([88a0b278](https://github.com/bszarlej/maratus/commit/88a0b27854dadc3bb85f74564ede218b366e3406))
 - **DOCS**: smooth positions through property setters. ([d301f255](https://github.com/bszarlej/maratus/commit/d301f25575bea04410d385149698ccbcaaf7daea))
 - **DOCS**: describe generated predictions. ([c447a4cd](https://github.com/bszarlej/maratus/commit/c447a4cdd2822518d1ae094193c53b24289d4864))
 - **DOCS**: remove chat example. ([cc8b3d1a](https://github.com/bszarlej/maratus/commit/cc8b3d1a8ed1b87a9ca3d428116531020cb9322d))
 - **DOCS**: describe spawners with entity visibility. ([e53a6b4d](https://github.com/bszarlej/maratus/commit/e53a6b4d4d818252322da89987b2e08e1b9d212a))
 - **DOCS**: describe scope events and spawner lookups. ([a4466ea2](https://github.com/bszarlej/maratus/commit/a4466ea2445a1e343683a08711955c16c8623126))
 - **DOCS**: describe prediction in components. ([d16f164e](https://github.com/bszarlej/maratus/commit/d16f164e40312a28d38ae8b5f5a54e3a88b1805e))
 - **DOCS**: add pub version and CI badges [skip ci]. ([585daf71](https://github.com/bszarlej/maratus/commit/585daf71f38cde4010786a4c4089a73591d4aaad))
 - **DOCS**: describe owner-written fields. ([148dfe69](https://github.com/bszarlej/maratus/commit/148dfe69687340b71f1693d0e9ba94db5174fbf1))
 - **DOCS**: correct setup and transport documentation. ([0875d1cb](https://github.com/bszarlej/maratus/commit/0875d1cbc222c8c94caad59cb7f5d0af657f87e1))

#### `maratus_generator` - `v0.1.4`

 - **FEAT**: apply interpolated fields through their setters. ([297866f6](https://github.com/bszarlej/maratus/commit/297866f66e0038036d6eb7e3684ebc76ce68d932))
 - **FEAT**: generate predictions from @Prediction. ([020422fc](https://github.com/bszarlej/maratus/commit/020422fc05042ecf6f74519fbc128c2e72e70c97))
 - **FEAT**: infer enum codecs. ([04804213](https://github.com/bszarlej/maratus/commit/048042136c565dd65640c325548a63332178e479))
 - **FEAT**: generate the writer of synchronized fields. ([ba709177](https://github.com/bszarlej/maratus/commit/ba709177a20003622001a076554690c4312ce7fb))
 - **DOCS**: describe smoothing received values. ([c1a907a5](https://github.com/bszarlej/maratus/commit/c1a907a57575df2b59716156122d3047a9086715))
 - **DOCS**: note that predictions are not generated yet. ([be792f2b](https://github.com/bszarlej/maratus/commit/be792f2b71b56a9a0ed33850df478a83d4b3fbbd))
 - **DOCS**: add pub version and CI badges [skip ci]. ([585daf71](https://github.com/bszarlej/maratus/commit/585daf71f38cde4010786a4c4089a73591d4aaad))
 - **DOCS**: correct generator documentation. ([5384c64c](https://github.com/bszarlej/maratus/commit/5384c64ca5990e0673722de981c3668074415d19))


## 2026-11-12

### Changes

---

Packages with breaking changes:

 - [`maratus` - `v0.3.0`](#maratus---v030)

Packages with other changes:

 - [`maratus_annotations` - `v0.1.3`](#maratus_annotations---v013)
 - [`maratus_enet` - `v0.1.1`](#maratus_enet---v011)
 - [`maratus_flame` - `v0.1.4`](#maratus_flame---v014)
 - [`maratus_webrtc` - `v0.1.1`](#maratus_webrtc---v011)
 - [`maratus_generator` - `v0.1.3`](#maratus_generator---v013)

Packages with dependency updates only:

> Packages listed below depend on other packages in this workspace that have had changes. Their versions have been incremented to bump the minimum dependency versions of the packages they depend upon in this project.

 - `maratus_annotations` - `v0.1.3`
 - `maratus_enet` - `v0.1.1`
 - `maratus_flame` - `v0.1.4`
 - `maratus_webrtc` - `v0.1.1`
 - `maratus_generator` - `v0.1.3`

---

#### `maratus` - `v0.3.0`

 - **DOCS**: update README.md. ([d056d8ce](https://github.com/bszarlej/maratus/commit/d056d8ced702261ed45b38db9f6f7dc8cbaead10))
 - **BREAKING** **FEAT**: batch state updates and optimize numeric encoding. ([8a3b7fd5](https://github.com/bszarlej/maratus/commit/8a3b7fd5577cda8079e2e1d9cf8f7bdec9ff04f9))
 - **BREAKING** **FEAT**: use compact binary encoding for session messages. ([38209f4d](https://github.com/bszarlej/maratus/commit/38209f4d51b52bc64fd0bad4ea729a8d4c10f34d))


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

