# 🍊 Mandarine

Convertisseur de fichiers local pour Mac (Apple Silicon et Intel, macOS 13+).

## Installation (utilisateurs)
Dans le Terminal :
```
curl -fsSL https://raw.githubusercontent.com/Winczlavv/Mandarine/main/install.sh | bash
```

## Utilisation
- Glisser un fichier + **⇧ Maj** → convertir · + **⌥ Option** → outils
- Sélectionner un fichier + **⌃⌥M** → roue cliquable (clic au centre pour basculer Convertir ⇄ Outils)
- **Clic droit → Services → Mandarine : Convertir… / Outils…**

Le résultat apparaît à côté de l'original. Mandarine se met à jour toute seule.

## Développement
- `./build.sh` compile pour ce Mac et installe dans /Applications.
- Publier une version : `git tag v1.1 && git push origin v1.1`. GitHub Actions compile les versions Apple Silicon et Intel (ffmpeg inclus) et crée la release.

## Licences
ffmpeg est intégré sous forme de binaire statique (builds de Martin Riedl, licence GPL). Source : https://ffmpeg.org · script de build : https://git.martin-riedl.de/ffmpeg/build-script
