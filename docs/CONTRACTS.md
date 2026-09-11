# Model contracts & versioning — FinTrack Perf & Scale

## Contexte

Les contrats dbt (`contract.enforced: true`) verrouillent le schéma d'un modèle :
dbt vérifie à chaque run que les colonnes définies dans le YML correspondent exactement
au SELECT du modèle SQL. Toute divergence fait échouer le build — ce qui protège les
consommateurs downstream (Metabase, Hightouch, Data Science) contre les breaking changes.

## Modèles publics

| Modèle | Accès | Contract | Consommateurs |
|--------|-------|----------|---------------|
| `fct_transactions` | public | `enforced: false` → à activer | Metabase, Hightouch, Data Science |
| `fct_transactions_v2` | public | non enforced | Migration progressive |
| `dim_comptes` | public | non enforced | Metabase, CRM sync |
| `dim_tenants` | public | non enforced | Tous les marts |
| `dim_categories` | public | non enforced | Rapports catégoriels |
| `mart_tenant_kpis_daily` | public | non enforced | Dashboard exécutif |
| `bridge_comptes_titulaires` | private | non enforced | Usage interne uniquement |

## Étapes pour activer `contract.enforced: true` sur `fct_transactions`

1. **Ajouter les `data_type` manquants** dans `_core.yml` pour toutes les colonnes de `fct_transactions` :

```yaml
- name: montant
  data_type: number
- name: devise
  data_type: varchar
- name: montant_eur
  data_type: number
- name: montant_signe
  data_type: number
- name: montant_signe_eur
  data_type: number
- name: frais
  data_type: number
- name: montant_net
  data_type: number
- name: type_operation
  data_type: varchar
- name: sens
  data_type: varchar
- name: moyen_paiement
  data_type: varchar
- name: canal
  data_type: varchar
- name: type_compte
  data_type: varchar
- name: customer_segment
  data_type: varchar
- name: pays_compte
  data_type: varchar
- name: nom_categorie
  data_type: varchar
- name: type_categorie
  data_type: varchar
- name: groupe
  data_type: varchar
- name: marchand_nom
  data_type: varchar
- name: marchand_categorie
  data_type: varchar
- name: marchand_pays
  data_type: varchar
- name: marchand_mcc
  data_type: number
- name: aml_score
  data_type: number
- name: aml_flag
  data_type: varchar
- name: fraud_score
  data_type: number
- name: is_flagged_for_review
  data_type: boolean
- name: is_reconciled
  data_type: boolean
- name: reconciliation_batch_id
  data_type: varchar
- name: source_system
  data_type: varchar
- name: created_at
  data_type: timestamp_ntz
- name: updated_at
  data_type: timestamp_ntz
- name: _loaded_at
  data_type: timestamp_ntz
- name: jour_transaction
  data_type: date
- name: semaine_transaction
  data_type: date
- name: mois_transaction
  data_type: date
- name: date_valeur
  data_type: timestamp_ntz
- name: date_settlement
  data_type: timestamp_ntz
```

2. **Activer le contract** dans `_core.yml` :

```yaml
config:
  contract:
    enforced: true
```

3. **Lancer `dbt build --select fct_transactions`** et vérifier qu'il passe.

## Versioning — fct_transactions v1 → v2

### Ce qui change en v2

| Colonne | v1 | v2 |
|---------|----|----|
| `montant_hors_taxes` | absente | `montant_eur / 1.20` pour les débits |

### Modèle v2

`fct_transactions_v2.sql` — construit sur `fct_transactions` avec le champ additionnel.
Consommateurs ciblés : équipe Finance pour reporting hors-taxes.

### Stratégie de migration

Quand un breaking change est nécessaire sur un modèle public :

1. Créer `fct_transactions_v2` avec les changements
2. Marquer v1 comme `deprecated` avec une date de retrait (minimum 30 jours)
3. Notifier les consommateurs via `exposures.yml`
4. Attendre la migration de tous les consommateurs
5. Supprimer v1

### Exemple YAML pour versioning dbt natif (dbt 1.9+)

```yaml
models:
  - name: fct_transactions
    latest_version: 2
    config:
      contract:
        enforced: true
    versions:
      - v: 1
        defined_in: fct_transactions
        deprecation_date: '2027-03-01'
      - v: 2
        defined_in: fct_transactions_v2
```

## Règles générales

- Tout modèle `public` doit avoir ses colonnes documentées dans le YML avant d'activer le contract
- Un changement de `data_type` sur une colonne existante est un **breaking change** → nouvelle version obligatoire
- L'ajout d'une colonne nullable n'est **pas** un breaking change → `on_schema_change: append_new_columns`
- La suppression d'une colonne est un **breaking change** → nouvelle version obligatoire
