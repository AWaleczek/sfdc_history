{# Helper to find the actual column name regardless of underscores #}
{%- macro find_col(cols, target) -%}
    {%- for c in cols -%}
        {%- if c.column | replace("_", "") | upper == target | upper -%}
            {{ return(c.column) }}
        {%- endif -%}
    {%- endfor -%}
    {{ return(target) }}  {# Fallback #}
{%- endmacro -%} test2.sql


{% macro pivot_sfdc_history(object_history_relation, object_relation, record_id) %}

    {# 1. Config #}
    {%- set fields_to_append_id = [
        "OWNER",
        "CREATEDBY",
        "LASTMODIFIEDBY",
        "ACCOUNT",
        "CONTACT",
    ] -%}
    {%- set raw_field_values = [] -%}

    {# 2. Dynamic Field Fetching with execute guard #}
    {%- if execute -%}
        {%- set fetched_values = dbt_utils.get_column_values(
            table=object_history_relation, column="field"
        ) -%}

        {%- for val in fetched_values -%}
            {# Slugify cleans special chars, replace removes the underscores it creates #}
            {%- set clean_val = dbt_utils.slugify(val) | replace("_", "") | upper -%}

            {%- if clean_val in fields_to_append_id -%}
                {%- do raw_field_values.append(clean_val ~ "ID") -%}
            {%- else -%} {%- do raw_field_values.append(clean_val) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}

    {%- set columns = adapter.get_columns_in_relation(object_history_relation) -%}

    {# Map the required History columns #}
    {%- set h_id = sfdc_history_utils.find_col(columns, "ID") -%}
    {%- set h_record_id = find_col(columns, record_id | replace("_", "") | upper) -%}
    {%- set h_old = find_col(columns, "OLDVALUE") -%}
    {%- set h_new = find_col(columns, "NEWVALUE") -%}
    {%- set h_date = find_col(columns, "CREATEDDATE") -%}
    {%- set h_user = find_col(columns, "CREATEDBYID") -%}
    {%- set h_field = find_col(columns, "FIELD") -%}
    {%- set h_type = find_col(columns, "DATATYPE") -%}

    with
        history_base as (select * from {{ object_history_relation }}),

        object_base as (select * from {{ object_relation }}),

        {# 4. Correct field names to match Salesforce API names #}
        history_corrected as (
            select
                {{ adapter.quote(h_id) }} as id,
                {{ adapter.quote(h_record_id) }} as recordid,
                {{ adapter.quote(h_old) }} as oldvalue,
                {{ adapter.quote(h_new) }} as newvalue,
                {{ adapter.quote(h_date) }} as createddate,
                {{ adapter.quote(h_user) }} as createdbyid,
                {{ adapter.quote(h_type) }} as datatype,
                case
                    {% for f in fields_to_append_id -%}
                        when
                            replace(upper({{ adapter.quote(h_field) }}), '_', '')
                            = '{{ f }}'
                        then '{{ f ~ "ID" }}'
                    {% endfor -%}
                    else replace(upper({{ adapter.quote(h_field) }}), '_', '')
                end as field
            from history_base
        ),

    {% if raw_field_values | length > 0 %}

            {# 5. Capture the 'OldValue' of the very first change to assist the Initial State #}
            first_changes_pivoted as (
                select
                    recordid,
                    {% for field_name in raw_field_values -%}
                        max(
                            case when field = '{{ field_name }}' then oldvalue end
                        ) as {{ field_name }}_init
                        {%- if not loop.last %},{% endif %}
                    {% endfor %}
                from
                    (
                        select
                            *,
                            row_number() over (
                                partition by recordid, field order by createddate asc
                            ) as rn
                        from history_corrected
                    )
                where rn = 1
                group by 1
            ),

            {# 6. Build the record's state as it was at the moment of creation #}
            initial_state as (
                select
                    concat(object_base.id, '_initial') as id,
                    object_base.id as recordid,
                    object_base.createddate as createddate,
                    object_base.createdbyid as createdbyid,
                    'initial' as changed_field,
                    'initial' as datatype,
                    {% for field_name in raw_field_values -%}
                        coalesce(
                            first_changes_pivoted.{{ field_name }}_init,
                            cast(object_base.{{ adapter.quote(field_name) }} as string)
                        ) as {{ field_name }}
                        {% if not loop.last %},{% endif %}
                    {% endfor %}
                from object_base
                left join
                    first_changes_pivoted
                    on object_base.id = first_changes_pivoted.recordid
            ),

            {# 7. Pivot all subsequent changes #}
            pivoted_history as (
                select
                    id,
                    recordid,
                    createddate,
                    createdbyid,
                    datatype,
                    field as changed_field,
                    {% for field_name in raw_field_values -%}
                        case
                            when field = '{{ field_name }}' then newvalue
                        end as {{ field_name }}
                        {%- if not loop.last %},{% endif %}
                    {% endfor %}
                from history_corrected
            ),

            {# 8. Combine Initial and History records #}
            all_history as (
                select *, true as is_initial_record
                from initial_state
                union all
                select *, false as is_initial_record
                from pivoted_history
            ),

            {# 9. Reconstruct the state at every point in time (Fill Down) #}
            filled_history as (
                select
                    id as change_id,
                    recordid,
                    createddate as change_date,
                    createdbyid as change_created_by_id,
                    datatype as change_datatype,
                    changed_field,
                    {% for field_name in raw_field_values -%}
                        last_value({{ field_name }} ignore nulls) over (
                            partition by recordid
                            order by
                                createddate,
                                (case when is_initial_record then 0 else 1 end)
                            rows between unbounded preceding and current row
                        ) as {{ field_name ~ "_changes" }},
                    {% endfor %}

                    is_initial_record,
                    row_number() over (
                        partition by recordid
                        order by
                            createddate desc,
                            (case when is_initial_record then 0 else 1 end) desc
                    )
                    = 1 as is_latest_change
                from all_history
            ),

            {# 10. Final Coalesce: Merge history with current record values and pull remaining static fields #}
            final_coalesced as (
                select

                    object_base.* exclude (
                        {% for field_name in raw_field_values %}
                            {{ adapter.quote(field_name) }}
                            {% if not loop.last %}, {% endif %}
                        {% endfor %}
                    ),

                    {% for field_name in raw_field_values -%}
                        coalesce(
                            filled_history.{{ field_name ~ "_changes" }},
                            cast(object_base.{{ adapter.quote(field_name) }} as string)
                        ) as {{ field_name }},
                    {% endfor %}

                    filled_history.change_id,
                    filled_history.changed_field,
                    filled_history.change_datatype,
                    filled_history.change_date,
                    filled_history.change_created_by_id,
                    filled_history.is_initial_record,
                    filled_history.is_latest_change
                from object_base
                inner join filled_history on object_base.id = filled_history.recordid
            )

        select *
        from final_coalesced
        order by id, change_date

    {% else %}
        {# Parsing fallback #}
        select * from {{ object_relation }} limit 0
    {% endif %}

{% endmacro %}
