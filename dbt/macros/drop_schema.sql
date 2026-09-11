{% macro drop_schema(schema_name) %}
    {%- set sql -%}
        DROP SCHEMA IF EXISTS {{ target.database }}.{{ schema_name }} CASCADE
    {%- endset -%}
    {% do run_query(sql) %}
    {{ log("Dropped schema: " ~ target.database ~ "." ~ schema_name, info=True) }}
{% endmacro %}
