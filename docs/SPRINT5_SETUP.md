# Sprint 5 — Setup CI/CD & Orchestration

## US 5.1 — GitHub Actions Slim CI

### Ce qui est en place
- `.github/workflows/dbt_ci.yml` — lint SQL + slim CI sur chaque PR vers `main` ou `staging`
- `dbt/profiles.yml` — targets `dev`, `ci`, `prod`
- `dbt/macros/drop_schema.sql` — cleanup automatique du schéma CI après chaque PR
- `dbt/macros/generate_schema_name.sql` — isole chaque PR dans `CI_<schema>_<PR_ID>`

### Étapes pour activer la CI

**1. Configurer les secrets GitHub**

Aller sur GitHub → `Settings` → `Secrets and variables` → `Actions` → `New repository secret` :

| Secret | Valeur |
|--------|--------|
| `SNOWFLAKE_ACCOUNT` | `sgwydcw-yzb07398` |
| `SNOWFLAKE_CI_USER` | ton user Snowflake |
| `SNOWFLAKE_CI_PASSWORD` | ton mot de passe Snowflake |

**2. Configurer le manifest de production**

Le workflow télécharge `manifest.json` depuis la prod pour le `--defer`.
Deux options :

- **Option A (dbt Cloud API)** — remplacer le placeholder dans `dbt_ci.yml` :
  ```bash
  curl -H "Authorization: Token $DBT_CLOUD_API_TOKEN" \
    "https://cloud.getdbt.com/api/v2/accounts/<account_id>/runs/<run_id>/artifacts/manifest.json" \
    -o prod-artifacts/manifest.json
  ```
  Ajouter `DBT_CLOUD_API_TOKEN` comme secret GitHub.

- **Option B (S3/GCS)** — stocker le manifest après chaque run prod et le télécharger :
  ```bash
  aws s3 cp s3://fintrack-dbt-artifacts/prod/manifest.json prod-artifacts/
  ```

**3. Tester la CI**

Créer une PR `dev` → `main` sur GitHub qui modifie un fichier dans `dbt/`.
La CI va :
1. Linter les fichiers SQL modifiés
2. Builder uniquement les modèles modifiés + leur downstream (`state:modified+`)
3. Supprimer le schéma CI à la fin

---

## US 5.2 — DAG Airflow

### Ce qui est en place
- `orchestration/airflow_dag_fintrack.py` — DAG complet avec 3 task groups

### Architecture du DAG

```
start
  └── ingestion
        ├── check_raw_freshness     (dbt source freshness, SLA 30min)
        └── check_row_counts        (alerte si table vide)
  └── dbt
        ├── dbt_deps
        ├── dbt_snapshot
        ├── dbt_run_staging         (SLA 20min)
        ├── dbt_run_marts           (SLA 30min)
        └── dbt_test
  └── reverse_etl
        ├── export_tenant_kpis      (SLA 10min)
        ├── export_compliance_report (SLA 10min)
        └── notify_success          (Slack)
  └── end
```

### Étapes pour déployer Airflow

**1. Installer Airflow**
```bash
pip install apache-airflow apache-airflow-providers-slack
```

**2. Configurer la connexion Slack**

Dans Airflow UI → `Admin` → `Connections` → `Add` :
- Conn ID : `slack_fintrack`
- Conn Type : `Slack Webhook`
- Password : URL du webhook Slack (ex: `https://hooks.slack.com/services/...`)

**3. Copier le DAG**
```bash
cp orchestration/airflow_dag_fintrack.py $AIRFLOW_HOME/dags/
```

**4. Vérifier que le DAG est détecté**
```bash
airflow dags list | grep fintrack
```

**5. Variables d'environnement requises**
```bash
export SNOWFLAKE_ACCOUNT=sgwydcw-yzb07398
export SNOWFLAKE_USER=senan
export SNOWFLAKE_PASSWORD=<mot_de_passe>
```

**6. Lancer manuellement pour tester**

Dans Airflow UI → `fintrack_pipeline` → `Trigger DAG`

### Schedule
- Toutes les 2h : `0 */2 * * *` (SLA gold tenants)
- Modifier le `schedule_interval` selon les besoins des tenants silver/bronze
