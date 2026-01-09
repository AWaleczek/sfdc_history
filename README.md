# Salesforce History Utils

This dbt package provides macros for reconstructing the state of Salesforce records over time using history tables (e.g., `CaseHistory`), creating a Slowly Changing Dimensions (SCD) table of Type 2

- [Salesforce History Utils](#salesforce-history-utils)
  - [Installation](#installation)
  - [Macros](#macros)
    - [pivot\_sfdc\_history (source)](#pivot_sfdc_history-source)
      - [Usage with ref()](#usage-with-ref)
      - [Usage with source()](#usage-with-source)
  - [Configuration](#configuration)
    - [Customizing ID Suffixes](#customizing-id-suffixes)
  - [Output Schema](#output-schema)
  - [Usage Notes](#usage-notes)
  - [Requirements](#requirements)
  - [License](#license)

## Installation

Add the following to your `packages.yml` file:

```yaml
packages:
  - git: "https://github.com/AWaleczek/sfdc_history.git"
    revision: v1.0.0 # Use the latest tag

```

## Macros

### pivot_sfdc_history ([source](https://www.google.com/search?q=macros/pivot_sfdc_history.sql))

This macro pivots the "tall" Salesforce history table into a "wide" format, creating one row per history event. It reconstructs the full state of the record at that point in time by "filling down" values from previous events.

**Key Features:**

- **State Reconstruction:** Creates the historic state of a record whenever a change in a tracked field occured.
- **ID Normalization:** Automatically appends `ID` to lookup fields (Owner, Account, etc.) to match standard Salesforce API naming.
- **Source Coalescing:** Joins with the base object table to have all other object meta data available.
- **Record Flags:** Includes an `is_latest_change` and `īs_initial_record` boolean for easy filtering in BI tools.
- **Change Indicator:** Each record has a `changed_field` column, indicating which field was impacted by the change.

#### Usage with ref()

```sql
{{ sfdc_history_utils.pivot_sfdc_history(
    object_history_relation = ref('stg_case_history'),
    object_relation = ref('stg_case')
) }}
```

#### Usage with source()

```sql
{{ sfdc_history_utils.pivot_sfdc_history(
    object_history_relation = source('salesforce', 'casehistory'),
    object_relation = source('salesforce', 'casehistory')
) }}
```

---

## Configuration

### Customizing ID Suffixes

Salesforce history tables often store field names as `Owner` or `Account`, but the base table stores them as `OwnerId` or `AccountId`. The macro handles the most common fields by default.

This is an issue that should only appear for standard ID fields. If you have an industry cloud or ID field that is not added yet, you add it yourself with a variable as below. I'd also appreciate if you could let me know, then I can add it in a new release. Add the following to your `dbt_project.yml`:

```yaml
vars:
  extra_history_id_fields:
    - "CO_OWNER"
    - "SLA_ACCOUNT"
    - "PRIMARY_CONTACT"

```

---

## Output Schema

| Column | Description |
| --- | --- |
| **[OBJECT_FIELDS]*** | All other original columns from the base Case table are included via Snowflake `EXCLUDE`. |
| **[FIELD_NAME]** | The reconstructed value of the field at that specific timestamp. |
| **CHANGE_ID** | Unique ID for the history event (or 'initial' for the start state). |
| **CHANGED_FIELD** | The field that was impacted by the change. |
| **CHANGE_DATATYPE** | Datatype of the changed field |
| **CHANGE_DATE** | The timestamp the change occurred. |
| **CHANGE_CREATED_BY_ID** | User ID of the user that triggered the change. |
| **IS_INITIAL_RECORD** | Boolean: True if this is the initial state of the record. |
| **IS_LATEST_CHANGE** | Boolean: True if this is the most recent state of the record. |

## Usage Notes

Certain changes, in particular changes of referenced objects (OwnerId, ProductId, etc.) will often create two records, one with a data type of `Text` (ie. 'Bob Bobson' -> Alice Alison) as well as one of datatype `EntityId` (ie. '123456abcdef' -> 'ghijkl123456'). You will need to filter out one of them to get accurate results.

## Requirements

- **Platform:** This macro is optimized for **Snowflake** (utilizes `IGNORE NULLS` and `EXCLUDE` syntax).
- **Dependencies:** Requires `dbt-labs/dbt_utils` version `1.1.0` or higher.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](https://www.google.com/search?q=LICENSE) file for details.
