# SteamOS-Win

Prototype d'une expérience « SteamOS-like » basée sur Windows, avec un objectif particulier : conserver le support NVIDIA natif et gérer correctement un écran ultrawide 32:9.

## V1 actuelle

- application WPF plein écran et sans bordure ;
- interface responsive : elle occupe l'écran sélectionné sans enfermer l'UI dans un cadre 16:9 ;
- sélection de l'écran actif et affichage de sa résolution ;
- détection de Steam via le registre et les chemins d'installation classiques ;
- lancement de Steam avec `-gamepadui` ;
- gestionnaire de session Steam : démarrage, détection de fermeture et relance après crash ;
- raccourci global `Ctrl` + `Alt` + `W` pour basculer entre les comptes ;
- bascule securisee vers une session deja ouverte, puis deconnexion de la session precedente ;
- option `--shell` pour lancer la session dédiée ;
- option `--dispatcher` pour choisir automatiquement entre Explorer et Steam selon le marqueur de l'installation ;
- aucune modification de Winlogon, du BCD ou du kernel Windows pendant le test.

## Tester

Depuis PowerShell à la racine du projet :

```powershell
dotnet run --project .\src\SteamOsWin.Shell\SteamOsWin.Shell.csproj
```

Pour tester le superviseur de session en mode shell :

```powershell
dotnet run --project .\src\SteamOsWin.Shell\SteamOsWin.Shell.csproj -- --shell
```

Le mode `--shell` lance Steam et le supervise. Il ne remplace pas encore le shell Windows au niveau de Winlogon.

En mode shell réel, la fenêtre SteamOS-Win est masquée : Steam reste l'interface visible. Si Steam se ferme, il est relancé. `Ctrl + Alt + W` demande le basculement vers l'autre session déjà ouverte ; l'ancienne session est déconnectée après le transfert réussi de la console et reste disponible pour le retour.

Le shell préserve également les composants configurés dans `background-services.json` : iCUE, SignalRGB, le daemon SteamSync, Apollo, DayNightLAN, le Steam Client Service et les services Bitdefender détectés sur cette machine. Les processus utilisateur sont lancés au besoin et contrôlés périodiquement ; les services Windows sont vérifiés puis démarrés seulement s'ils sont arrêtés. Aucun de ces composants n'est stoppé lorsque tu quittes SteamOS-Win. Le fichier JSON est copié à côté de l'exécutable et peut être adapté si un chemin change.

## Intégration du shell

`Install-SteamOsWin.ps1` est volontairement en aperçu par défaut. Il ne modifie Winlogon que lorsqu'on passe explicitement `-Apply`, sauvegarde le BCD et l'ancienne valeur `Shell`, puis installe un dispatcher :

- marqueur `normal` : le dispatcher lance `explorer.exe` ;
- marqueur `steam` : le dispatcher garde `SteamOsWin` comme shell et supervise Steam.

Ce mécanisme configure une installation Windows donnée. Le marqueur n'est pas transmis par le BCD : il est propre à chaque installation, ce qui est précisément pourquoi le double démarrage doit utiliser une seconde installation, une partition ou un VHDX Windows.

Exemples, depuis PowerShell administrateur :

```powershell
.\scripts\Install-SteamOsWin.ps1 -Mode steam
.\scripts\Install-SteamOsWin.ps1 -Mode steam -AllowMachineShell -Apply
.\scripts\Install-SteamOsWin.ps1 -Restore -Apply
```

Important : ce script est réservé au scénario legacy d'une installation secondaire ou d'un VHDX. Il refuse désormais `-Mode steam -Apply` sans `-AllowMachineShell`, précisément pour éviter de casser le shell du Windows principal. Pour le Windows principal, utilise `Install-PerUserSteamDispatcher.ps1` ; `HKLM\Winlogon\Shell` doit rester `explorer.exe`.

Pour obtenir un vrai choix au démarrage, il faut une deuxième installation Windows ou un Windows installé dans un VHDX. Le même dossier `SteamOsWin` doit être installé dans chaque environnement, avec `-Mode normal` dans Windows normal et `-Mode steam` dans l'environnement gaming. Le menu est ensuite ajouté avec :

```powershell
.\scripts\Install-BootEntry.ps1 -WindowsRoot W:\ -Description "SteamOS-Win"
.\scripts\Install-BootEntry.ps1 -WindowsRoot W:\ -Description "SteamOS-Win" -Apply
```

Pour un VHDX Windows déjà installé et stocké sur le disque principal :

```powershell
.\scripts\Install-VhdxBootEntry.ps1 -VhdxPath "C:\VM\SteamOS-Win.vhdx" -Description "SteamOS-Win"
.\scripts\Install-VhdxBootEntry.ps1 -VhdxPath "C:\VM\SteamOS-Win.vhdx" -Description "SteamOS-Win" -Apply
```

Ce script ne crée pas l'image Windows et ne l'installe pas : il ajoute uniquement le VHDX déjà amorçable au Windows Boot Manager, après sauvegarde du BCD. Une fois démarré dans ce Windows secondaire, publie puis installe SteamOS-Win avec `-Mode steam -Apply`. Dans l'installation principale, conserve Explorer ou utilise `-Mode normal`.

## Préparer le Windows secondaire

L'ISO installe un Windows complet. Pour transformer le VHDX en environnement SteamOS-like, copie d'abord le payload depuis le Windows principal vers un dossier situé sur un disque de données visible par les deux installations :

```powershell
New-Item -ItemType Directory -Path "E:\SteamOsWin\payload" -Force | Out-Null
Copy-Item -LiteralPath "C:\Projets\SteamOs on Windows\publish\win-x64" -Destination "E:\SteamOsWin\payload\publish\win-x64" -Recurse -Force
Copy-Item -LiteralPath "C:\Projets\SteamOs on Windows\scripts" -Destination "E:\SteamOsWin\payload\scripts" -Recurse -Force
```

Après le premier démarrage dans le VHDX, exécute le script depuis PowerShell administrateur. Il réalise d'abord un aperçu :

```powershell
& "E:\SteamOsWin\payload\scripts\Configure-SteamOsWinGuest.ps1"
```

Pour appliquer le profil SteamOS-like :

```powershell
& "E:\SteamOsWin\payload\scripts\Configure-SteamOsWinGuest.ps1" -PublishedPath "E:\SteamOsWin\payload\publish\win-x64" -Debloat -InstallShell -Apply
```

`Configure-SteamOsWinGuest.ps1` retire uniquement une liste conservative d'applications grand public, désactive les suggestions, Widgets/Copilot et OneDrive par stratégie, mais conserve Microsoft Store, WebView2, Windows Update, les composants NVIDIA, Steam, .NET et Visual C++. Le nettoyage AppX est sauvegardé dans `C:\ProgramData\SteamOsWin\pre-debloat-packages.json` ; il est recommandé de faire cette opération seulement dans le VHDX secondaire.

Le script inspecte `D:` et `E:` par défaut, leurs labels, leur système de fichiers, leur espace libre et les dossiers `SteamLibrary`, `Games`, `Steam` et `Vortex Mods`. Il ne lance ni `format`, ni `diskpart`, ni modification de partition. Les bibliothèques de jeux restent donc intactes. Si Windows leur attribue une autre lettre dans le VHDX, il faut la vérifier dans Gestion des disques puis ajouter le dossier existant dans Steam : Steam ne retélécharge pas les jeux déjà présents lorsqu'on sélectionne leur bibliothèque.

Les services iCUE, SteamSync, DayNightLAN, Apollo, Bitdefender et SignalRGB sont démarrés seulement s'ils sont réellement installés dans ce Windows secondaire. Une installation présente dans le Windows principal n'est pas automatiquement partagée avec le VHDX ; le rapport `C:\ProgramData\SteamOsWin\guest-setup-state.json` indique les services manquants.

## Mode par utilisateur sous Windows Pro

Un deuxième Windows n'est pas obligatoire pour l'expérience quotidienne. Le mode recommandé utilise un shell Winlogon **par utilisateur** : `SteamGaming` démarre directement `SteamOsWin` puis Steam, tandis que le compte normal conserve le shell machine natif `explorer.exe`. Explorer ne se lance donc pas dans la session gaming et une session ne peut plus casser l'autre.

Depuis PowerShell **administrateur**, commence par vérifier la configuration :

```powershell
& "C:\Projets\SteamOs on Windows\scripts\Install-PerUserSteamDispatcher.ps1" `
  -UserName "SteamGaming" `
  -PublishedPath "C:\Projets\SteamOs on Windows\publish\win-x64"
```

Puis applique-la :

```powershell
& "C:\Projets\SteamOs on Windows\scripts\Install-PerUserSteamDispatcher.ps1" `
  -UserName "SteamGaming" `
  -PublishedPath "C:\Projets\SteamOs on Windows\publish\win-x64" `
  -Mode steam -CleanUserStartup -Apply
```

`-CleanUserStartup` est facultatif : il retire de la clé de démarrage de **SteamGaming** les lanceurs non essentiels (avec sauvegarde restaurable), en conservant les entrées qui mentionnent Steam, NVIDIA, Bitdefender, iCUE, SignalRGB, Apollo, DayNight ou SteamSync. Il ne touche pas au démarrage du compte normal.

Le script sauvegarde la configuration du profil cible et les démarrages utilisateur. Il ne remplace plus la valeur `HKLM\...\Winlogon\Shell` : le compte normal reste donc sur Explorer. Pour désactiver le shell Steam de `SteamGaming` :

```powershell
& "C:\Projets\SteamOs on Windows\scripts\Install-PerUserSteamDispatcher.ps1" -Restore -Apply
```

Le changement de session depuis SteamOS-Win utilise `Ctrl` + `Alt` + `W`. En cas de problème d'affichage, connecte-toi au compte normal et exécute la commande de restauration ci-dessus avant de redémarrer.

Le shell par utilisateur ne coupe pas arbitrairement les services système : RPC, audio, réseau, HID/manettes, Plug and Play, alimentation, NVIDIA, anti-cheat et les composants de sécurité restent nécessaires. Il supprime surtout Explorer et les applications de démarrage liées au bureau dans `SteamGaming`. Le gestionnaire conserve les services demandés dans `background-services.json` : Apollo, DayNightLAN, Steam Client Service, Bitdefender, iCUE, SignalRGB et SteamSync lorsqu'ils sont installés. Cela améliore surtout le chemin connexion → Steam et la consommation au repos ; il ne faut pas promettre un gain d'images/seconde important dans les jeux.

Le script `Install-UserSteamSession.ps1` reste disponible comme solution de test sans modification de Winlogon :

```powershell
& "C:\Projets\SteamOs on Windows\scripts\Install-UserSteamSession.ps1" -PublishedPath "C:\Projets\SteamOs on Windows\publish\win-x64"
& "C:\Projets\SteamOs on Windows\scripts\Install-UserSteamSession.ps1" -PublishedPath "C:\Projets\SteamOs on Windows\publish\win-x64" -Apply -RequireGameDrives
```

Ce mode de test copie le binaire dans le profil courant et ajoute un lancement `HKCU` uniquement pour cet utilisateur. Explorer peut alors apparaître brièvement avant d'être arrêté ; utilise le dispatcher ci-dessus pour le mode final sans Explorer.

Pour retirer le lancement automatique du mode de test :

```powershell
& "C:\Projets\SteamOs on Windows\scripts\Install-UserSteamSession.ps1" -Restore
```

Le mode par utilisateur partage naturellement les installations et les volumes `D:`/`E:`. Steam peut utiliser les bibliothèques existantes directement ; ajoute une fois leurs dossiers dans Paramètres > Stockage. Les droits NTFS doivent autoriser `SteamGaming` à lire et écrire dans les dossiers de bibliothèque. Le script vérifie ces volumes et ne les formate ni ne les repartitionne.

Le changement rapide d'utilisateur laisse les programmes de l'autre session ouverts. Pour conserver le maximum de mémoire et éviter qu'une session Steam reste active en arrière-plan, préfère te déconnecter avant de passer d'un compte à l'autre. Le Shell Launcher officiel reste réservé aux éditions Enterprise, Education et IoT Enterprise ; sur Pro, ce mode repose volontairement sur un lanceur par utilisateur.

### Bascule Ctrl + Alt + W

Pour activer la bascule sans mot de passe entre `Euxane` et `SteamGaming`, exécute une fois depuis PowerShell administrateur, après `Publish.ps1` :

```powershell
.\scripts\Install-SessionSwitch.ps1 -NormalUserName "Euxane" -GamingUserName "SteamGaming" -Apply
```

Le script installe un broker SYSTEM limité à deux opérations fixes : transférer la session cible déjà ouverte vers la console avec `tscon`, puis déconnecter l'ancienne session avec `WTSDisconnectSession`. La session reste donc connectée en arrière-plan, ce qui permet le retour inverse sans mot de passe. Il installe aussi un agent caché au login d'`Euxane`; le shell SteamOS-Win porte le raccourci dans `SteamGaming`. Aucun mot de passe n'est demandé lorsque la session cible existe déjà. Si elle n'a jamais été ouverte depuis le démarrage, le raccourci affiche un message et ne déconnecte pas la session courante.

Pour retirer cette fonction :

```powershell
.\scripts\Install-SessionSwitch.ps1 -Restore -Apply
```

Pour créer automatiquement ce VHDX à partir d'une ISO Windows, utilise `New-SteamOsWinVhdx.ps1`. L'outil monte l'ISO en lecture seule, affiche les index disponibles et ne crée rien sans `-Apply` :

```powershell
.\scripts\New-SteamOsWinVhdx.ps1 -IsoPath "C:\Telechargements\Win11.iso" -ListImages
.\scripts\New-SteamOsWinVhdx.ps1 -IsoPath "C:\Telechargements\Win11.iso" -VhdxPath "E:\SteamOsWin\SteamOS-Win.vhdx" -ImageIndex 6 -SizeGB 120 -Apply
```

Le script utilise les cmdlets Hyper-V si elles existent, sinon bascule automatiquement sur `diskpart.exe`, intégré à Windows. Il laisse le VHDX sur le disque s'il y a une erreur afin de ne jamais supprimer tes données automatiquement.

Le premier appel est sans effet et sert à contrôler les chemins. Le second sauvegarde le BCD avant d'ajouter l'entrée. Pour retirer une entrée créée par le script :

```powershell
.\scripts\Uninstall-BootEntry.ps1
.\scripts\Uninstall-BootEntry.ps1 -Apply
```

Cette architecture utilise Windows Boot Manager plutôt que GRUB : elle conserve Secure Boot et évite de modifier le kernel. Microsoft documente la création d'entrées BCD séparées, tout en avertissant que leur modification nécessite des privilèges administrateur et peut rendre le démarrage inopérant ; c'est pourquoi les scripts sont en aperçu par défaut. Shell Launcher reste l'option native pour les éditions Enterprise, Education et IoT Enterprise.

Sur Windows Enterprise, Education ou IoT Enterprise, `Configure-ShellLauncher.ps1` utilise le fournisseur WMI officiel et configure le shell pour un compte précis :

```powershell
.\scripts\Configure-ShellLauncher.ps1 -UserName ".\SteamUser"
.\scripts\Configure-ShellLauncher.ps1 -UserName ".\SteamUser" -Apply
.\scripts\Configure-ShellLauncher.ps1 -UserName ".\SteamUser" -Restore -Apply
```

Il active les composants `Client-DeviceLockdown` et `Client-EmbeddedShellLauncher` seulement avec `-Apply`. Le script doit être exécuté avec Windows PowerShell 5.1, pas nécessairement PowerShell 7.

## Publier une version locale

```powershell
.\scripts\Publish.ps1
```

Le résultat est produit dans `publish\win-x64`.

## Roadmap

1. Valider le comportement 5120×1440 et le lancement Steam.
2. Ajouter la détection des jeux et les raccourcis manette.
3. Finaliser la session `SteamGaming` et la vérification des bibliothèques D/E.
4. Ajouter un écran de sortie de session et les réglages manette.
5. Conserver le VHDX uniquement comme scénario de test isolé si nécessaire.
