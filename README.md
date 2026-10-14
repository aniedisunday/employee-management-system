# Employee Management System: Database Design in SQL

A relational database for managing employees, their documents and their postings to client sites, written in MySQL 8. Everything is in one script, [`employee_management_system.sql`](employee_management_system.sql): database creation, tables, indexes, sample data, views and queries.

![Entity relationship diagram](erd.png)

---

## The business problem

A staffing company employs two kinds of people. **Direct staff** run the company itself: HR, finance, IT and supervisors. **Deployed staff** (security guards, drivers and close protection officers) are recruited for client companies and posted to the clients' warehouses, offices and residences, often moving between sites over time.

All of this was being tracked in spreadsheets and shared folders. As the company grew, everyday questions became hard to answer:

- **Who is posted where right now?** When a client calls about a guard, finding that person meant searching several out-of-date spreadsheets.
- **Is every site fully staffed?** Each client has agreed how many guards they need at each site, but nobody could see the shortfall at a glance.
- **Is every deployed employee properly vetted?** Everyone must provide a signed offer letter, an ID and two signed guarantor forms. Finding the gaps meant opening every folder.
- **What happened to someone who left?** Leavers' rows were deleted or overwritten, so their history was lost.
- **Who has looked at sensitive documents?** There was no record of who opened what.
- **Can the data be trusted?** Spreadsheets accept anything: a guard at two sites at once, a leaver with no leaving date, a vehicle recorded against a guard.

## How the database solves it

### One record, connected properly

Employees, positions, departments, staff categories, clients, sites, documents and guarantors each have their own table, joined by foreign keys. The design is normalised to **third normal form**: each fact is stored once, and values that can be worked out (full name, years of service, current posting, document counts) are calculated in views rather than stored, so they can never go out of date.

The staff category sits on the **position**, not the employee. Choosing someone's position decides whether they are direct or deployed, and a line manager is a **self-referencing foreign key** on `Employees`.

### Who is posted where, with full history

The `Assignments` table records every posting: who, which site, what role, what shift, from and to which date. Postings are closed, never overwritten, so the whole history is kept.

A person cannot be at two sites at once, so only **one open posting per employee** is allowed. MySQL has no filtered unique index, so this uses a stored generated column with a unique index on it:

```sql
OpenAssignment INT GENERATED ALWAYS AS
    (CASE WHEN EndDate IS NULL THEN EmployeeID ELSE NULL END) STORED,
CONSTRAINT UX_Assignments_OneOpen UNIQUE (OpenAssignment)
```

The column holds the employee's ID only while a posting is open. Closed postings become `NULL`, and MySQL allows any number of `NULL`s in a unique index.

Site shortfalls come from a `LEFT JOIN` with `GROUP BY` and `HAVING`:

```sql
SELECT c.ClientName, s.SiteName, s.GuardsRequired, COUNT(a.AssignmentID) AS GuardsPosted
FROM ClientSites s
JOIN Clients c ON c.ClientID = s.ClientID
LEFT JOIN Assignments a
       ON a.SiteID = s.SiteID AND a.EndDate IS NULL AND a.AssignmentRole = 'Guard'
GROUP BY c.ClientName, s.SiteID, s.SiteName, s.GuardsRequired
HAVING COUNT(a.AssignmentID) < s.GuardsRequired;
```

```
+--------------------+-------------------------+----------------+--------------+
| ClientName         | SiteName                | GuardsRequired | GuardsPosted |
+--------------------+-------------------------+----------------+--------------+
| Crestway Logistics | Ojota Depot             |              3 |            1 |
| Northgate Retail   | Oregun Warehouse        |              2 |            0 |
| Harbourline Group  | Harbourline Head Office |              3 |            2 |
+--------------------+-------------------------+----------------+--------------+
```

### Vetting gaps found by a query

Document requirements are stored as **data, not code**. `DocumentTypes` says which documents are mandatory, how many are needed (two guarantor forms) and which staff category they apply to (a driving licence for drivers only). A new requirement is a new row, not a schema change.

The `vw_DocumentCompliance` view joins every current employee to every requirement that applies to them, counts the verified documents they hold, and flags the gaps (excerpt of the output):

```
+-------------+-------------------+---------------+-------------------------+---------------+---------------+
| StaffNumber | FullName          | StaffCategory | TypeName                | VerifiedCount | RequiredCount |
+-------------+-------------------+---------------+-------------------------+---------------+---------------+
| EMP-0005    | Grace Adeyinka    | Guard         | Guarantor Form          |             1 |             2 |
| EMP-0007    | Ifeanyi Nwachukwu | Guard         | Guarantor Form          |             0 |             2 |
| EMP-0007    | Ifeanyi Nwachukwu | Guard         | Means of Identification |             0 |             1 |
| EMP-0010    | Fatima Lawal      | Guard         | Signed Offer Letter     |             0 |             1 |
+-------------+-------------------+---------------+-------------------------+---------------+---------------+
```

### History that is never lost

Leavers are never deleted. Their status changes and an exit date and reason are recorded. Every status change (leave, suspension, return, exit) is written to `EmployeeStatusHistory` with its own dates, while `Employees` holds only the current status, so the next change cannot overwrite the last.

The foreign key from `Assignments` to `Employees` deliberately has **no cascade**, so deleting an employee who has posting history fails instead of silently destroying it.

### Sensitive data and audit trail

- The national ID number is stored encrypted as `VARBINARY`, with a separate hash column for duplicate checks and only the last four digits kept for display.
- Files are stored on disk. The database keeps the path and a SHA-256 hash to detect tampering.
- `AuditLog` records who created, updated, viewed, verified or assigned what, and when.

### Rules enforced by the database

Business rules live in the schema as CHECK constraints and foreign keys, so bad data is refused whatever tries to save it:

```sql
-- A leaver must have an exit date, and a current employee must not
CONSTRAINT CHK_Employees_Exit CHECK (
    (EmploymentStatus IN ('Resigned','Retired','Terminated','Contract Ended') AND ExitDate IS NOT NULL)
    OR
    (EmploymentStatus IN ('Active','On Leave','Suspended') AND ExitDate IS NULL)
)

-- A vehicle registration belongs only on a driver's posting
CONSTRAINT CHK_Assignments_Vehicle CHECK (VehicleRegNo IS NULL OR AssignmentRole = 'Driver')

-- Only document file types, never an executable
CONSTRAINT CHK_Documents_Mime CHECK (MimeType IN ('application/pdf', 'image/jpeg', 'image/png'))
```

Each rule was tested by deliberately breaking it:

```
ERROR 1062: Duplicate entry '4' for key 'Assignments.UX_Assignments_OneOpen'
ERROR 3819: Check constraint 'CHK_Employees_Exit' is violated
ERROR 3819: Check constraint 'CHK_Assignments_Vehicle' is violated
ERROR 3819: Check constraint 'CHK_Documents_Mime' is violated
ERROR 1451: Cannot delete or update a parent row: a foreign key constraint fails
```

## The outcome

Each of the business questions is now answered by a single query instead of a search through spreadsheets and folders, the history is kept, and bad data is refused at the point of entry.

## What is in the script

| Section | Contents |
|---|---|
| 1. Database creation | `CREATE DATABASE` with `utf8mb4` |
| 2. Tables | 15 tables, 19 foreign keys, 25 CHECK constraints |
| 3. Indexes | 18 indexes on foreign keys and the columns used for searching and filtering |
| 4. Sample data | 12 employees, 3 clients, 5 sites, 9 postings, 32 documents and their related records (all fictional) |
| 5. Views | `vw_EmployeeDirectory`, `vw_DocumentCompliance`, `vw_SiteStaffing` |
| 6. Queries | 11 queries showing multi-table joins, LEFT JOIN, self join, GROUP BY with HAVING, WITH ROLLUP, CTEs and window functions (`LAG`, `RANK`) |
| 7. Rule checks | Statements that break each business rule, commented out, with the error each one produces |

| Table | Purpose |
|---|---|
| `Employees` | Central employee record, with line manager as a self join |
| `Departments`, `Positions`, `StaffCategories` | Organisation structure |
| `Clients`, `ClientSites` | Client companies and their individual sites |
| `Assignments` | Postings of employees to client sites, with history |
| `Skills`, `EmployeeSkills` | Skills, linked to employees through a junction table |
| `DocumentTypes`, `EmployeeDocuments` | Document requirements and the documents held |
| `Guarantors` | Guarantors, linked to their signed forms |
| `EmployeeStatusHistory` | Every status period with dates and reasons |
| `Users`, `AuditLog` | System users and the record of what they did |

## How to run

Requires MySQL 8.0.16 or later (earlier versions ignore CHECK constraints).

```bash
mysql -u root -p < employee_management_system.sql
```

The script drops and recreates the `EmployeeManagementSystem` database, loads the sample data and prints the result of every query. It can also be opened and run in MySQL Workbench.
