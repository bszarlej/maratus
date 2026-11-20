## 0.4.0

> Note: This release has breaking changes.

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

## 0.3.0

> Note: This release has breaking changes.

 - **DOCS**: update README.md. ([d056d8ce](https://github.com/bszarlej/maratus/commit/d056d8ced702261ed45b38db9f6f7dc8cbaead10))
 - **BREAKING** **FEAT**: batch state updates and optimize numeric encoding. ([8a3b7fd5](https://github.com/bszarlej/maratus/commit/8a3b7fd5577cda8079e2e1d9cf8f7bdec9ff04f9))
 - **BREAKING** **FEAT**: use compact binary encoding for session messages. ([38209f4d](https://github.com/bszarlej/maratus/commit/38209f4d51b52bc64fd0bad4ea729a8d4c10f34d))

## 0.2.0

> Note: This release has breaking changes.

 - **FEAT**: send RPCs and fields with their delivery settings. ([ce4ae28d](https://github.com/bszarlej/maratus/commit/ce4ae28d723ee5557650913c317a18505b06c8e5))
 - **FEAT**: add unreliable delivery and channels to the in-memory network. ([4412c2aa](https://github.com/bszarlej/maratus/commit/4412c2aaa5e9c75b83c9dbc9f0421e948f486dc5))
 - **DOCS**: describe delivery modes and channels. ([f9b3032e](https://github.com/bszarlej/maratus/commit/f9b3032e993ee76adb6941ef566fad3057b4ba6b))
 - **BREAKING** **FEAT**: add delivery settings to RPC and field handles. ([d97a380e](https://github.com/bszarlej/maratus/commit/d97a380e2ea3df1f7c3a317060eda0ce1cde332b))

## 0.1.2

 - **FEAT**: replicate session membership to clients. ([70904a7e](https://github.com/bszarlej/maratus/commit/70904a7edba8924d8e5a3a84999d06c31d9297fc))
 - **FEAT**: add membership messages to the protocol. ([2f7d7cf9](https://github.com/bszarlej/maratus/commit/2f7d7cf920c4e1253f48c507161f9064a23bf357))
 - **FEAT**: return the authority of departed clients to the host. ([82b55aaa](https://github.com/bszarlej/maratus/commit/82b55aaa161d0106bb04a40aee22356d3a666350))
 - **FEAT**: switch synchronizer roles on authority transfers. ([1468262e](https://github.com/bszarlej/maratus/commit/1468262eefb35ead5195c0de21962d95de5ee04f))
 - **FEAT**: transfer entity authority at runtime. ([e6e6f023](https://github.com/bszarlej/maratus/commit/e6e6f0238acc9073de459d1223aabab7d78cdbbd))
 - **FEAT**: add authority transfer messages to the protocol. ([b71e2bcd](https://github.com/bszarlej/maratus/commit/b71e2bcde65af77f0d930aa25a5292a9b4bb0c71))
 - **DOCS**: describe player membership on clients. ([f6fca075](https://github.com/bszarlej/maratus/commit/f6fca07549d4d1b8b706ee1f53d42307aaf2d911))
 - **DOCS**: describe authority transfers and their guarantees. ([882f7860](https://github.com/bszarlej/maratus/commit/882f7860d234bdaadd979bf1c6e3a04c91daedd2))

## 0.1.1

 - **FEAT**(maratus): add WireList for list-shaped wire values.
 - **FEAT**(maratus): register existing handles with the schema builder.
 - **DOCS**(maratus): show registering a schema by hand and with annotations.

## 0.1.0

* Initial release.
