# Salesforce History Utils

This dbt package provides advanced macros for reconstructing the state of Salesforce records over time using history tables (e.g., `CaseHistory`).

## Installation

Add the following to your `packages.yml` file:

```yaml
packages:
  - git: "[https://github.com/YOUR_GITHUB_USERNAME/sfdc_history_utils.git](https://github.com/YOUR_GITHUB_USERNAME/sfdc_history_utils.git)"
    revision: v1.0.0 # Use the latest tag

```

## Macros

### pivot_sfdc_history ([source](https://www.google.com/search?q=macros/pivot_sfdc_history.sql))

This macro pivots the "tall" Salesforce history table into a "wide" format, creating one row per history event. It reconstructs the full state of the record at that point in time by "filling down" values from previous events.

**Key Features:**

* **State Reconstruction:** Uses `last_value` with `IGNORE NULLS` to ensure every row contains the full record state.
* **ID Normalization:** Automatically appends `ID` to lookup fields (Owner, Account, etc.) to match standard Salesforce API naming.
* **Source Coalescing:** Joins with the base object table to ensure the latest record matches the current "live" data.
* **Latest Change Flag:** Includes an `is_latest_change` boolean for easy filtering in BI tools.

#### Usage

```sql
{{ sfdc_history_utils.pivot_sfdc_history(
    history_relation = ref('stg_case_history'),
    case_relation = ref('stg_case')
) }}

```

---

## Configuration

### Customizing ID Suffixes

Salesforce history tables often store field names as `Owner` or `Account`, but the base table stores them as `OwnerId` or `AccountId`. The macro handles the most common fields by default.

To add your own custom lookup fields or additional standard fields to this logic, add a variable to your `dbt_project.yml`:

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
| **CHANGEID** | Unique ID for the history event (or 'initial' for the start state). |
| **CHANGEDATE** | The timestamp the change occurred. |
| **CHANGEDATATYPE** | 'Initial' for the record creation or 'History' for subsequent changes. |
| **IS_LATEST_CHANGE** | Boolean: True if this is the most recent state of the record. |
| **[FIELD_NAME]** | The reconstructed value of the field at that specific timestamp. |
| **[CASE_FIELDS]*** | All other original columns from the base Case table are included via Snowflake `EXCLUDE`. |

## Requirements

* **Platform:** This macro is optimized for **Snowflake** (utilizes `IGNORE NULLS` and `EXCLUDE` syntax).
* **Dependencies:** Requires `dbt-labs/dbt_utils` version `1.1.0` or higher.

## License

This project is licensed under the Apache License 2.0 - see the [LICENSE](https://www.google.com/search?q=LICENSE) file for details.
