# App icon — original artwork

`app-bundle/assets/AppIcon-1024.png` is **original artwork for this project**,
generated deterministically by `app-bundle/make_custom_icon.py`:

- light "paper" tile (matching the official app's light icon family),
- a bold dark-navy letter **D**,
- a cyan terminal cursor in the counter of the D.

It is drawn from signed-distance primitives in pure Python and contains no
third-party or DeepSeek trademark artwork. No official DeepSeek whale/logo
asset is bundled or redistributed. The icon is therefore safe to redistribute
with this package.

To regenerate:

```sh
python3 app-bundle/make_custom_icon.py
python3 app-bundle/make_app_icon.py <outdir>   # resizes to all iOS slots
```

To use a different 1024×1024 PNG, overwrite `app-bundle/assets/AppIcon-1024.png`
and rerun `make_app_icon.py`.
