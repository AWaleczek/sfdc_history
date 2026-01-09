{% macro pivot_sfdc_history(history_relation, case_relation) %}

    {# 1. Config #}
    {%- set fields_to_append_id = ["OWNER", "CREATEDBY", "LASTMODIFIEDBY", "ACCOUNT", "CONTACT"] -%}
    {%- set raw_field_values = [] -%}

    {# 2. Dynamic Field Fetching with execute guard #}
    {%- if execute -%}
        {%- set fetched_values = dbt_utils.get_column_values(
            table=history_relation, column="upper(field)"
        ) -%}

        {%- for val in fetched_values -%}
            {%- if val in fields_to_append_id -%}
                {%- do raw_field_values.append(val ~ "ID") -%}
            {%- else -%} 
                {%- do raw_field_values.append(val) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}

    with
        history_base as (select * from {{ history_relation }}),

        case_base as (select * from {{ case_relation }}),

        {# 4. Correct field names to match Salesforce API names #}
        history_corrected as (
            select
                id,
                caseid,
                oldvalue,
                newvalue,
                createddate,
                createdbyid,
                datatype,
                case
                    {% for f in fields_to_append_id -%}
                        when upper(field) = '{{ f }}' then '{{ f  ~ "ID" }}'
                    {% endfor -%}
                    else upper(field)
                end as field
            from history_base
        ),

    {% if raw_field_values | length > 0 %}

        {# 5. Capture the 'OldValue' of the very first change to assist the Initial State #}
        first_changes_pivoted as (
            select
                caseid,
                {% for field_name in raw_field_values -%}
                    max(case when field = '{{ field_name }}' then oldvalue end) as {{ field_name }}_init
                    {%- if not loop.last %},{% endif %}
                {% endfor %}
            from (
                select *, row_number() over (partition by caseid, field order by createddate asc) as rn
                from history_corrected
            )
            where rn = 1
            group by 1
        ),

        {# 6. Build the record's state as it was at the moment of creation #}
        initial_state as (
            select
                concat(case_base.id, '_initial') as id,
                case_base.id as caseid,
                case_base.createddate as createddate,
                case_base.createdbyid as createdbyid,
                'Initial' as datatype,
                {% for field_name in raw_field_values -%}
                    coalesce(
                        first_changes_pivoted.{{ field_name }}_init,
                        cast(case_base.{{ adapter.quote(field_name) }} as string)
                    ) as {{ field_name }}
                    {% if not loop.last %},{% endif %}
                {% endfor %}
            from case_base 
            left join first_changes_pivoted on case_base.id = first_changes_pivoted.caseid
        ),

        {# 7. Pivot all subsequent changes #}
        pivoted_history as (
            select
                id,
                caseid,
                createddate,
                createdbyid,
                datatype,
                {% for field_name in raw_field_values -%}
                    case when field = '{{ field_name }}' then newvalue end as {{ field_name }}
                    {%- if not loop.last %},{% endif %}
                {% endfor %}
            from history_corrected
        ),

        {# 8. Combine Initial and History records #}
        all_history as (
            select *, true as is_initial_record from initial_state
            union all
            select *, false as is_initial_record from pivoted_history
        ),

        {# 9. Reconstruct the state at every point in time (Fill Down) #}
        filled_history as (
            select
                id as changeid,
                caseid,
                createddate as changedate,
                createdbyid as changecreatedbyid,
                datatype as changedatatype,

                {% for field_name in raw_field_values -%}
                    last_value({{ field_name }} ignore nulls) over (
                        partition by caseid
                        order by createddate, (case when is_initial_record then 0 else 1 end)
                        rows between unbounded preceding and current row
                    ) as {{ field_name ~ "_changes" }},
                {% endfor %}

                is_initial_record,
                row_number() over (
                    partition by caseid
                    order by createddate desc, (case when is_initial_record then 0 else 1 end) desc
                ) = 1 as is_latest_change
            from all_history
        ),

        {# 10. Final Coalesce: Merge history with current Case values and pull remaining static fields #}
        final_coalesced as (
            select
                

                case_base.* exclude (
                    {% for field_name in raw_field_values %}
                        {{ adapter.quote(field_name) }}
                        {% if not loop.last %}, {% endif %}
                    {% endfor %}
                ),

                filled_history.changeid,
                filled_history.changedatatype,
                filled_history.changedate,
                filled_history.changecreatedbyid,
                filled_history.is_initial_record,
                filled_history.is_latest_change,

                {% for field_name in raw_field_values -%}
                    coalesce(
                        filled_history.{{ field_name ~ "_changes" }},
                        cast(case_base.{{ adapter.quote(field_name) }} as string)
                    ) as {{ field_name }}{% if not loop.last %}, {% endif %}
                {% endfor %}
            from case_base
            inner join filled_history on case_base.id = filled_history.caseid
        )

    select * from final_coalesced order by id, changedate

    {% else %}
        {# Parsing fallback #}
        select * from {{ case_relation }} limit 0
    {% endif %}

{% endmacro %}