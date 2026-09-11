# FinTrack Perf & Scale — Le pipeline qui étouffait

---

## Le contexte : une success story qui devient un problème

FinTrack Analytics a réussi son pivot. En 18 mois, la fintech est passée d'une app grand public à une **plateforme analytique en marque blanche** licenciée à 15 banques européennes — BNP Paribas, Crédit Agricole, ING, Deutsche Bank, Revolut, Qonto…

Le succès a un prix. Chaque banque déverse ses flux en temps réel. Résultat : **50 à 100 millions de transactions par mois**, 1 million de comptes actifs, des données en 10 devises, multi-langues, multi-fuseaux.

Et le pipeline dbt hérité n'a pas suivi.

---

## Le problème : 4 heures. Chaque nuit.

Le CTO convoque l'équipe data un lundi matin. Il pose trois chiffres sur la table :

- **4 heures** — le temps que prend `dbt run` en production
- **8 000 $/mois** — le coût des warehouses Snowflake, sans aucune traçabilité
- **0** — le nombre de personnes qui savent pourquoi

Les SLA contractuels avec les tenants gold exigent une fraîcheur des données toutes les **2 heures**. Un pipeline de 4h, c'est un contrat rompu toutes les nuits.

Les modèles reconstruisent des tables gigantesques from scratch à chaque run. Personne n'a pensé à l'incrémental. Personne ne sait ce qui coûte quoi. Et l'équipe finance réclame depuis 6 mois une visibilité sur le rapprochement bancaire.

La mission est claire : **diviser par 4 le temps d'exécution, diviser par 2 les coûts, et livrer une modélisation qui peut aller en production**.

---

## Sprint 1 — Poser des fondations solides

Avant de toucher au moindre modèle dbt, il faut reconstruire l'infrastructure.

Snowflake était configuré avec un seul rôle, un seul warehouse. Tout le monde faisait tout. Les ingestions bloquaient les requêtes BI. Les développeurs testaient en prod.

On repart de zéro avec **5 warehouses dédiés** — un pour l'ingestion, un pour les transformations dbt, un pour le reporting BI, un pour l'ad-hoc, un pour le dev. Et **5 rôles séparés** avec des droits précis. Un resource monitor pour alerter à 75%, suspendre à 90%, couper à 100%.

Puis on génère le dataset de test : **1 million de transactions**, 80 colonnes, 8 tables, chargées dans Snowflake via `PUT` + `COPY INTO`. Le terrain de jeu est prêt.

---

## Sprint 2 — Modéliser ce qui manquait

Le pipeline existant avait des trous. Des modèles marqués `TODO` qui retournaient des placeholders. Des joins manquants. Des données ignorées.

On complète :

- **`dim_categories`** — la hiérarchie de catégories n'était pas résolue. Une récursion SQL (`WITH RECURSIVE`) suffit à construire les chemins complets et les racines.
- **`fct_virements`** — les virements n'avaient qu'une ligne par virement. En finance, un virement c'est deux jambes : une sortante, une entrante. On implémente la double-écriture.
- **`bridge_comptes_titulaires`** — les comptes joints existaient dans les données mais pas dans la modélisation. On crée la table de liaison avec un `allocation_factor` pour ventiler les montants par titulaire.

Le modèle Kimball prend sa forme définitive.

---

## Sprint 3 — Le cœur du problème : l'incrémental

C'est ici que tout se joue.

La table `fct_transactions` est reconstruite entièrement à chaque run. Sur 1 million de lignes en scale M, c'est supportable. Sur 100 millions en production, c'est 4 heures.

La solution : **ne reprocesser que le delta**.

On passe sur une stratégie `merge` avec une fenêtre de lookback paramétrable :

```sql
where _loaded_at >= (select dateadd('day', -{{ var('incremental_lookback_days', 7) }}, max(_loaded_at)) from {{ this }})
```

7 jours par défaut. 1 jour en dev. 30 jours pour un backfill. Tout ça sans toucher au code.

**Le résultat : 25 secondes.** Au lieu de reconstruire 1 million de lignes, dbt ne retraite que le delta des 7 derniers jours.

On teste aussi la stratégie `microbatch` de dbt 1.9 — l'idée est séduisante : traiter jour par jour, paralléliser. En pratique, sur 2 ans de données historiques, ça crée 730 batches séquentiels. Le full-refresh tourne plus de 5 heures avant qu'on l'annule.

**Verdict : merge gagne. Le microbatch reste un prototype de benchmark.**

On analyse aussi le clustering : `average_depth = 2.0` sur `fct_transactions`. L'objectif était < 3. Atteint.

---

## Sprint 4 — La mémoire du système

Un tenant compliance pose la question : *"Quel était le statut KYC du compte 12345 le 15 mars dernier ?"*

Sans historisation, la réponse est impossible. La table ne garde que l'état courant.

On implémente le **SCD Type 2** sur `dim_comptes` via les snapshots dbt. À chaque run, dbt détecte les changements sur les colonnes sensibles — statut, kyc_level, aml_flag, is_pep. Il crée une nouvelle version du compte avec les dates de validité.

On simule 3 changements sur des comptes de test et on vérifie :

```
Compte 1 : actif → suspendu → clôturé  (3 versions, is_current = TRUE sur la dernière)
Compte 2 : kyc basic → advanced → intermediate
Compte 3 : aml clean → suspicious → manual_review
```

La piste d'audit réglementaire est en place.

On règle aussi le problème du **FX historisé** : `montant_eur` est recalculé au taux du jour exact de la transaction via `int_fx_rates_daily`. Écart mesuré sur 10 transactions : **0.00**.

---

## Sprint 5 — Industrialiser

Un pipeline qui tourne en local, c'est un prototype. Un pipeline industrialisé, c'est autre chose.

**GitHub Actions** : à chaque Pull Request vers `main`, la CI tourne automatiquement. Elle lint le SQL des fichiers modifiés, build uniquement les modèles impactés dans un schéma isolé `CI_<PR_ID>`, puis nettoie derrière elle. Pas de surprise en production.

**Airflow** : le DAG orchestre le pipeline complet en 3 actes — ingestion (freshness check), dbt (snapshot → staging → marts → tests), reverse ETL (export vers les systèmes consommateurs). Notification Slack en cas d'échec. SLA par task group.

---

## Sprint 6 — Ce que les données racontent

Avec un pipeline fiable, on peut enfin poser les vraies questions analytiques.

**Cohortes de rétention** : on mesure le taux d'utilisateurs actifs mois par mois depuis leur ouverture de compte. Qui reste ? Qui part ? Sur quelle fenêtre ?

**Détection d'anomalies** : une transaction est anormale si son montant s'écarte de plus de 3 écarts-types de la moyenne mobile sur 90 jours du compte. Un Z-score. Simple, robuste, expliquable à un compliance officer.

**Contracts** : `fct_transactions` est le modèle le plus consommé. Metabase, Hightouch, l'équipe Data Science en dépendent. On crée `fct_transactions_v2` avec un champ `montant_hors_taxes` sans casser les consommateurs existants. La migration est progressive, documentée, avec une date de dépréciation.

---

## Les résultats

| Avant | Après |
|-------|-------|
| `dbt run` : 4h | Run incrémental : **25s** |
| Coûts opaques | Query tags + resource monitors par warehouse |
| Aucune historisation | SCD2 opérationnel, piste d'audit réglementaire |
| Pipeline monolithique | CI/CD, DAG Airflow, 56 tests dbt |
| 0 modèle analytics | Cohortes, anomalies, KPIs tenants |

**Gain de performance : x576 sur le run incrémental.**

---

## Et pour 10× le volume ?

1 milliard de transactions par mois. Voilà ce que FinTrack devra absorber dans 3 ans si la croissance continue.

La réponse n'est pas "tout refaire". C'est d'appliquer les mêmes principes à plus grande échelle :

- Multi-cluster sur WH_TRANSFORM (jusqu'à 5 clusters en parallèle)
- Microbatch reconsidéré — avec des fenêtres journalières et un vrai parallélisme cloud, il devient pertinent
- Search Optimization sur `transaction_id` et `external_transaction_id` pour les lookups compliance
- Dynamic Tables Snowflake pour le near-real-time sur les agrégats critiques
- Partitionnement par tenant pour isoler les workloads des plus gros clients

L'architecture posée ici est conçue pour évoluer. Les fondations sont là.
