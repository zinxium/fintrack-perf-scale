# Design decisions — FinTrack Perf & Scale

## Modélisation

### Choix Kimball vs Data Vault

Approche **Kimball** retenue pour les raisons suivantes :
- Équipe analytique principale consommatrice (Metabase, Data Science) — schéma étoile plus accessible
- Volumes maîtrisés (< 100M lignes) — pas besoin de la scalabilité extrême du Data Vault
- Time-to-value prioritaire — modèles Kimball plus rapides à livrer et maintenir
- SCD Type 2 sur `dim_comptes` couvre les besoins d'historisation réglementaire

### Grain des tables de faits

- `fct_transactions` : une ligne = une transaction validée ou en_attente, non-reversal
- `fct_virements` : une ligne = une **leg** de virement (sortant OU entrant → 2 lignes par virement physique)
- `fct_transactions_microbatch` : prototype microbatch — non utilisé en prod (voir PERF_LOG)

### Bridge tables

- `bridge_comptes_titulaires` : relation many-to-many entre comptes et titulaires physiques
  - `allocation_factor` = 1 / nb_titulaires_actifs → permet la ventilation des montants par personne
  - Historisation via `date_debut` / `date_fin` + `is_active`
  - Types de relation : `principal`, `cotitulaire`, `mandataire`, `tuteur`

## Matérialisations

| Modèle | Matérialisation | Raison |
|--------|-----------------|--------|
| `stg_*` (hors transactions) | view | Pas de stockage, transformation légère |
| `stg_transactions` | incremental (merge) | 50-100M lignes, updates de statut post-insertion |
| `fct_transactions` | incremental (merge) | Idem — `merge_update_columns` ciblés pour minimiser le coût |
| `fct_transactions_v2` | incremental (merge) | Variante avec `montant_hors_taxes` — migration progressive |
| `int_transactions_normalisees` | ephemeral | Évite matérialisation intermédiaire coûteuse |
| `int_fx_rates_daily` | table | Petit volume (~6 500 lignes), requêté par tous les faits |
| `dim_*` | table | Dimensions stables, rebuild rapide |
| `bridge_comptes_titulaires` | table | Volume modéré, jointures fréquentes |
| `mart_*` | table | Agrégats consommés par BI — lecture optimisée |
| `snapshot_comptes` | snapshot (check) | Historisation SCD2 via dbt snapshots |

## Clustering keys

| Table | Clustering key | Justification |
|-------|----------------|---------------|
| `raw_transactions` | `(tenant_id, date_transaction)` | Filtres BI dominants — tenant + période |
| `raw_comptes` | `(tenant_id, date_ouverture)` | Multi-tenant, requêtes par cohorte |
| `raw_fx_rates` | `(date_cotation)` | Toujours filtré par date |
| `fct_transactions` | `(tenant_id, date_trunc('month', date_transaction))` | Pruning efficace — depth 2.0 mesuré |
| `raw_compte_titulaires` | `(compte_id)` | Lookups fréquents par compte |

> Note : `DATE_TRUNC` retiré des CLUSTER BY dans les DDL RAW (non supporté pendant COPY INTO).
> Appliqué uniquement sur les tables dbt (Snowflake le supporte dans ce contexte).

## SCD Type 2

Pattern retenu pour `dim_comptes_scd2` :
- Stratégie `check` avec `check_cols` sur les colonnes métier sensibles
- Colonnes surveillées : `statut`, `kyc_level`, `aml_flag`, `email`, `type_compte`, `customer_segment`, `is_pep`
- Colonnes techniques : `dbt_valid_from`, `dbt_valid_to`, `is_current`, `version_number`, surrogate key (`dim_compte_sk`)
- Contrainte : exactement 1 ligne avec `is_current = true` par `compte_id` (validée par test dbt)

## Stratégie incrémentale

### Merge (retenu)

```
unique_key        = transaction_id
merge_update_cols = statut, is_reconciled, aml_flag, aml_score, fraud_score, montant_eur, updated_at
lookback          = var('incremental_lookback_days', 7)  — paramétrable
on_schema_change  = append_new_columns
```

**Raison du choix merge vs microbatch :**
- Les transactions changent de statut après insertion (`en_attente` → `validee`)
- Microbatch remplace le batch entier sans merge row-by-row → perte des mises à jour
- Benchmark mesuré : merge ~25s vs microbatch full-refresh >5h sur scale M

### Microbatch (prototype uniquement)

Créé comme modèle de benchmark `fct_transactions_microbatch`. Non déployé en prod.
Résultats : inadapté pour backfill (730 batches séquentiels sur 2 ans de données).

## Multi-devises

- Référentiel FX dans `int_fx_rates_daily` (forward-fill week-ends via window function)
- `montant_eur` recalculé dans `fct_transactions` au taux du jour de la transaction
- Écart mesuré entre taux source et taux référentiel : 0.00 sur échantillon de 100 transactions

## Convention de nommage

| Préfixe | Type | Exemple |
|---------|------|---------|
| `stg_` | Staging | `stg_transactions` |
| `int_` | Intermediate (ephemeral) | `int_fx_rates_daily` |
| `dim_` | Dimension | `dim_comptes_scd2` |
| `fct_` | Fact | `fct_transactions` |
| `bridge_` | Bridge | `bridge_comptes_titulaires` |
| `mart_` | Mart analytique | `mart_cohortes_retention` |
| `snapshot_` | Snapshot SCD2 | `snapshot_comptes` |

## Query tags

Format : `team=<team>|project=<project>|target=<target>`

Positionné automatiquement via `on-run-start` → permet le tracking des coûts dans `QUERY_HISTORY`.

## Gouvernance

- Modèles `public` : accessibles par tous les groupes — `dim_tenants`, `dim_comptes`, `fct_transactions`, `fct_virements`
- Modèles `private` : usage interne uniquement — `bridge_comptes_titulaires`
- Groupe `core` : propriété de la Data Platform Team (`data-platform@fintrack.example`)
- Contracts dbt : `enforced: true` à activer sur `fct_transactions` après stabilisation du schéma (voir CONTRACTS.md)
