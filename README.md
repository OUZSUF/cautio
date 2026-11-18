# Cautio : suivi des cautions des marchés publics (Maroc)

Application simple pour les entreprises qui travaillent avec l'État, les communes et les offices :
elle dit quand déposer une caution, quand demander la mainlevée et quand récupérer l'argent.

## Ce que fait l'application

- Cautions provisoires, définitives, retenues de garantie et avances.
- Montants calculés automatiquement : définitive 3 % du marché, retenue 10 % par décompte plafonnée à 7 %.
- Alertes : définitive non déposée à temps, caution qui expire, mainlevée possible, original à rendre à la banque.
- Lettre de demande de mainlevée prête à imprimer.
- Liste des banques marocaines (19 banques, 5 banques participatives, fenêtres participatives, CDG, TGR, Tamwilcom).
- Chaque utilisateur ne voit que ses propres données (Row Level Security de Supabase).

## Fichiers

| Fichier | Rôle |
|---|---|
| `index.html` | L'application (une seule page, déjà reliée au projet Supabase). |
| `schema_supabase.sql` | Tables, calculs, alertes et règles de sécurité à exécuter dans Supabase › SQL Editor. |

## Cadre juridique pris en compte

- Décret n° 2-22-431 du 8 mars 2023 relatif aux marchés publics (cautionnement provisoire, art. 24).
- CCAG-Travaux, décret n° 2-14-394 du 13 mai 2016 (cautionnement définitif, retenue de garantie, restitution).
- Dahir n° 1-56-211 du 8 juin 1956 relatif aux garanties pécuniaires.
- Décret n° 2-14-272 du 14 mai 2014 relatif aux avances.

Les taux et délais par défaut sont dans la table `parametres_juridiques`. Le CPS de chaque marché reste prioritaire :
ses clauses se saisissent dans la fiche du marché.

## Installer sur un autre projet Supabase

1. Exécuter `schema_supabase.sql` dans SQL Editor.
2. Dans `index.html`, remplacer l'URL et la clé `anon` de l'objet `PRESET` par celles du projet (Settings › API).
3. Dans Authentication › Sign In / Providers, désactiver « Confirm email » si les utilisateurs doivent entrer sans confirmation.

La clé `anon` est faite pour être publique : la sécurité repose sur les règles RLS de la base.
Ne jamais mettre la clé `service_role` dans ce dépôt.
