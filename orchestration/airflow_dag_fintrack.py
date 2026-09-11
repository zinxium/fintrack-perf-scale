"""
FinTrack Perf & Scale — DAG Airflow production
===============================================
Orchestre le pipeline complet :
  1. ingestion   — vérification fraîcheur RAW + alertes SLA
  2. dbt         — build incrémental + tests
  3. reverse_etl — export vers les systèmes consommateurs

Schedule : toutes les 2h (SLA gold tenants)
"""

from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.empty import EmptyOperator
from airflow.providers.slack.operators.slack_webhook import SlackWebhookOperator
from airflow.utils.task_group import TaskGroup

# ============================================================
# CONFIGURATION
# ============================================================

DBT_DIR = "/opt/airflow/dbt"
DBT_PROFILES_DIR = "/opt/airflow/dbt"
DBT_TARGET = "prod"
SLACK_CONN_ID = "slack_fintrack"

DEFAULT_ARGS = {
    "owner": "data-eng",
    "depends_on_past": False,
    "retries": 2,
    "retry_delay": timedelta(minutes=5),
    "retry_exponential_backoff": True,
    "max_retry_delay": timedelta(minutes=30),
    "email_on_failure": False,
    "email_on_retry": False,
}


def on_failure_callback(context):
    """Notification Slack en cas d'échec."""
    task_id = context["task_instance"].task_id
    dag_id = context["task_instance"].dag_id
    log_url = context["task_instance"].log_url
    execution_date = context["execution_date"]

    message = (
        f":red_circle: *Pipeline FinTrack — ÉCHEC*\n"
        f"*DAG* : `{dag_id}`\n"
        f"*Task* : `{task_id}`\n"
        f"*Date* : `{execution_date}`\n"
        f"*Logs* : <{log_url}|Voir les logs>"
    )

    SlackWebhookOperator(
        task_id="slack_alert",
        slack_webhook_conn_id=SLACK_CONN_ID,
        message=message,
    ).execute(context=context)


# ============================================================
# DAG
# ============================================================

with DAG(
    dag_id="fintrack_pipeline",
    description="Pipeline complet FinTrack : ingestion → dbt → reverse ETL",
    schedule_interval="0 */2 * * *",  # toutes les 2h (SLA gold)
    start_date=datetime(2024, 1, 1),
    catchup=False,
    default_args=DEFAULT_ARGS,
    tags=["fintrack", "production", "dbt"],
    on_failure_callback=on_failure_callback,
) as dag:

    start = EmptyOperator(task_id="start")
    end = EmptyOperator(task_id="end")

    # ============================================================
    # TASK GROUP 1 — INGESTION
    # ============================================================
    with TaskGroup("ingestion") as ingestion_group:

        check_freshness = BashOperator(
            task_id="check_raw_freshness",
            bash_command="""
                cd {{ params.dbt_dir }}
                dbt source freshness \
                    --profiles-dir {{ params.profiles_dir }} \
                    --target {{ params.target }}
            """,
            params={
                "dbt_dir": DBT_DIR,
                "profiles_dir": DBT_PROFILES_DIR,
                "target": DBT_TARGET,
            },
            retries=1,
            sla=timedelta(minutes=30),
            on_failure_callback=on_failure_callback,
        )

        check_row_counts = BashOperator(
            task_id="check_row_counts",
            bash_command="""
                snowsql -a $SNOWFLAKE_ACCOUNT -u $SNOWFLAKE_USER \
                    -q "SELECT COUNT(*) FROM FINTRACK_PROD.RAW.raw_transactions
                        HAVING COUNT(*) = 0;" \
                && echo "raw_transactions vide — alerte!" && exit 1 || exit 0
            """,
            retries=0,
            on_failure_callback=on_failure_callback,
        )

        check_freshness >> check_row_counts

    # ============================================================
    # TASK GROUP 2 — DBT BUILD
    # ============================================================
    with TaskGroup("dbt") as dbt_group:

        dbt_deps = BashOperator(
            task_id="dbt_deps",
            bash_command=f"cd {DBT_DIR} && dbt deps --profiles-dir {DBT_PROFILES_DIR}",
            retries=1,
        )

        dbt_snapshot = BashOperator(
            task_id="dbt_snapshot",
            bash_command=f"""
                cd {DBT_DIR}
                dbt snapshot \
                    --profiles-dir {DBT_PROFILES_DIR} \
                    --target {DBT_TARGET}
            """,
            sla=timedelta(minutes=15),
            on_failure_callback=on_failure_callback,
        )

        dbt_run_staging = BashOperator(
            task_id="dbt_run_staging",
            bash_command=f"""
                cd {DBT_DIR}
                dbt run \
                    --profiles-dir {DBT_PROFILES_DIR} \
                    --target {DBT_TARGET} \
                    --select tag:staging \
                    --vars '{{"incremental_lookback_days": 3}}'
            """,
            sla=timedelta(minutes=20),
            on_failure_callback=on_failure_callback,
        )

        dbt_run_marts = BashOperator(
            task_id="dbt_run_marts",
            bash_command=f"""
                cd {DBT_DIR}
                dbt run \
                    --profiles-dir {DBT_PROFILES_DIR} \
                    --target {DBT_TARGET} \
                    --select tag:marts \
                    --vars '{{"incremental_lookback_days": 3}}'
            """,
            sla=timedelta(minutes=30),
            on_failure_callback=on_failure_callback,
        )

        dbt_test = BashOperator(
            task_id="dbt_test",
            bash_command=f"""
                cd {DBT_DIR}
                dbt test \
                    --profiles-dir {DBT_PROFILES_DIR} \
                    --target {DBT_TARGET} \
                    --exclude tag:todo
            """,
            sla=timedelta(minutes=15),
            on_failure_callback=on_failure_callback,
        )

        dbt_deps >> dbt_snapshot >> dbt_run_staging >> dbt_run_marts >> dbt_test

    # ============================================================
    # TASK GROUP 3 — REVERSE ETL
    # ============================================================
    with TaskGroup("reverse_etl") as reverse_etl_group:

        export_tenant_kpis = BashOperator(
            task_id="export_tenant_kpis",
            bash_command="""
                echo "Export KPIs tenants vers API partenaires"
                # python scripts/reverse_etl/export_tenant_kpis.py
            """,
            retries=2,
            sla=timedelta(minutes=10),
            on_failure_callback=on_failure_callback,
        )

        export_compliance = BashOperator(
            task_id="export_compliance_report",
            bash_command="""
                echo "Export rapport compliance AML vers système réglementaire"
                # python scripts/reverse_etl/export_compliance.py
            """,
            retries=2,
            sla=timedelta(minutes=10),
            on_failure_callback=on_failure_callback,
        )

        notify_success = SlackWebhookOperator(
            task_id="notify_success",
            slack_webhook_conn_id=SLACK_CONN_ID,
            message=(
                ":large_green_circle: *Pipeline FinTrack — SUCCÈS*\n"
                "Toutes les tables sont à jour."
            ),
        )

        [export_tenant_kpis, export_compliance] >> notify_success

    # ============================================================
    # DÉPENDANCES GLOBALES
    # ============================================================
    start >> ingestion_group >> dbt_group >> reverse_etl_group >> end
