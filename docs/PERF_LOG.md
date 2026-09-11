# Performance Log — FinTrack Perf & Scale

À remplir pendant la mission. Ce document est un livrable obligatoire.

## Chargement initial

| Scale | Taille CSV (Go) | Durée génération | Durée PUT | Durée COPY | Erreurs |
|-------|-----------------|------------------|-----------|------------|---------|
| M     |                 |                  |           |            |         |
| L     |                 |                  |           |            |         |
| XL    |                 |                  |           |            |         |

## Baseline (avant optimisations)

Warehouse : ______  Target : ______  Date : ______

| Modèle | Rows | Bytes | Elapsed (s) | Partitions scanned | Credits |
|--------|------|-------|-------------|--------------------|---------|
| stg_transactions |  |  |  |  |  |
| fct_transactions |  |  |  |  |  |
| mart_solde_journalier |  |  |  |  |  |
| mart_tenant_kpis_daily |  |  |  |  |  |
| **Full run** |  |  |  |  |  |

## Après optimisations Sprint 3

Warehouse : ______  Target : ______  Date : ______

| Modèle | Rows | Bytes | Elapsed (s) | Partitions scanned | Credits | Gain |
|--------|------|-------|-------------|--------------------|---------|------|
| stg_transactions |  |  |  |  |  |  |
| fct_transactions |  |  |  |  |  |  |
| **Full run** |  |  |  |  |  |  |

## Clustering Analysis — fct_transactions (Sprint 3)

Date : 2026-09-08 | Scale : M (945 243 lignes) | Warehouse : WH_TRANSFORM

```json
{
  "cluster_by_keys": "LINEAR(tenant_id, date_trunc('month', date_transaction))",
  "total_partition_count": 8,
  "average_overlaps": 1.75,
  "average_depth": 2.0
}
```

**Résultat :** `average_depth = 2.0` < 3 → objectif atteint. Clustering efficace sur scale M.
À réévaluer sur scale L (10M+ lignes) où la profondeur augmentera naturellement.

## Search Optimization — fct_transactions

Date : 2026-09-08

```json
{
  "BuildCosts":    { "value": 0.000879, "unit": "Credits" },
  "StorageCosts":  { "value": 0.000037, "unit": "TB/mois" },
  "MaintenanceCosts": "Insufficient data (table < 7 jours)"
}
```

**Décision : non activée.** Sur scale M le coût est négligeable mais le bénéfice aussi.
À activer sur scale L/XL si les lookups sur `external_transaction_id` ou `iban` deviennent fréquents (dashboards compliance, rapprochement bancaire).

## Analyse Query Profile

Date : 2026-09-08 | Warehouse : WH_REPORTING (ou ADHOC) | Scale M

### Query 1 — Agrégat par tenant et mois

```sql
SELECT tenant_id, mois_transaction, SUM(montant_eur), COUNT(*)
FROM fct_transactions GROUP BY 1, 2 ORDER BY 1, 2;
```

- **Elapsed :** 702 ms
- **Résultat :** 192 lignes (8 tenants × 24 mois)
- **Profil :** scan full table + agrégat — efficace grâce au clustering sur `tenant_id`
- **Recommandation :** envisager une `dynamic table` ou `materialized view` sur cet agrégat en prod si rafraîchissement < 1h requis

### Query 2 — Point lookup par transaction_id

```sql
SELECT * FROM fct_transactions WHERE transaction_id = 500000;
```

- **Elapsed :** 482 ms
- **Résultat :** 1 ligne
- **Profil :** scan de partitions — `transaction_id` n'est pas dans la clustering key, Snowflake doit scanner toutes les partitions
- **Recommandation :** activer Search Optimization sur `transaction_id` si ce type de lookup est fréquent (support client, debugging)

### Query 3 — Filtre AML

```sql
SELECT tenant_id, COUNT(*), AVG(aml_score)
FROM fct_transactions WHERE aml_flag != 'clean' GROUP BY 1;
```

- **Elapsed :** 390 ms
- **Résultat :** 8 lignes
- **Profil :** le filtre `aml_flag != 'clean'` élimine ~98.5% des lignes — très sélectif
- **Recommandation :** sur scale L, envisager une table matérialisée `mart_aml_suspects` pour éviter le scan complet

## Décisions prises

- **Clustering key sur fct_transactions :** `(tenant_id, date_trunc('month', date_transaction))` → Justification : requêtes BI filtrées par tenant et période
- **Search Optimization :** non activée sur scale M → coût < bénéfice ; à réévaluer sur scale L sur `transaction_id` et `external_transaction_id`
- **Merge vs Microbatch :** merge retenu → raison : les transactions changent de statut après insertion (`en_attente` → `validee`), ce que microbatch ne gère pas (remplace le batch entier sans merge row-by-row)

## Coûts Snowflake

| Semaine | Credits WH_INGESTION | Credits WH_TRANSFORM | Credits WH_REPORTING | Total |
|---------|----------------------|----------------------|----------------------|-------|
|         |                      |                      |                      |       |
