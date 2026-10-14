/*
============================================================================
 EMPLOYEE MANAGEMENT SYSTEM - DATABASE DESIGN
============================================================================
 Design   : Normalised to Third Normal Form (3NF)
============================================================================
*/

-- ============================================================================
-- SECTION 1: DATABASE CREATION
-- ============================================================================

DROP DATABASE IF EXISTS EmployeeManagementSystem;

CREATE DATABASE EmployeeManagementSystem
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_unicode_ci;

USE EmployeeManagementSystem;


-- ============================================================================
-- SECTION 2: TABLES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Table 1: Users
-- People who can sign in to the system. Kept separate from Employees because
-- most employees never log in.
-- ----------------------------------------------------------------------------
CREATE TABLE Users (
    UserID        INT AUTO_INCREMENT PRIMARY KEY,
    FullName      VARCHAR(150) NOT NULL,
    Email         VARCHAR(150) NOT NULL UNIQUE,
    PasswordHash  VARCHAR(255) NOT NULL,
    Role          VARCHAR(20)  NOT NULL DEFAULT 'Viewer',
    IsActive      TINYINT(1)   NOT NULL DEFAULT 1,
    CreatedAt     DATETIME     NOT NULL DEFAULT (UTC_TIMESTAMP()),
    CONSTRAINT CHK_Users_Role  CHECK (Role IN ('Admin', 'HR', 'Operations', 'Viewer')),
    CONSTRAINT CHK_Users_Email CHECK (Email LIKE '%_@__%.__%')
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 2: Departments
-- ----------------------------------------------------------------------------
CREATE TABLE Departments (
    DepartmentID    INT AUTO_INCREMENT PRIMARY KEY,
    DepartmentName  VARCHAR(100) NOT NULL UNIQUE,
    Description     VARCHAR(255) NULL
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 3: StaffCategories
-- IsDeployed marks the categories that may be posted to a client site.
-- New categories can be added as rows without changing the schema.
-- ----------------------------------------------------------------------------
CREATE TABLE StaffCategories (
    StaffCategoryID  INT AUTO_INCREMENT PRIMARY KEY,
    CategoryName     VARCHAR(50)  NOT NULL UNIQUE,
    Description      VARCHAR(255) NULL,
    IsDeployed       TINYINT(1)   NOT NULL DEFAULT 0
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 4: Positions
-- The staff category sits on the position, so choosing a position decides
-- whether an employee is direct or deployed.
-- ----------------------------------------------------------------------------
CREATE TABLE Positions (
    PositionID       INT AUTO_INCREMENT PRIMARY KEY,
    PositionTitle    VARCHAR(100) NOT NULL,
    DepartmentID     INT          NOT NULL,
    StaffCategoryID  INT          NOT NULL,
    CONSTRAINT FK_Positions_Departments FOREIGN KEY (DepartmentID)
        REFERENCES Departments(DepartmentID),
    CONSTRAINT FK_Positions_Categories FOREIGN KEY (StaffCategoryID)
        REFERENCES StaffCategories(StaffCategoryID),
    CONSTRAINT UQ_Positions_TitleDept UNIQUE (PositionTitle, DepartmentID)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 5: Clients
-- Companies the business supplies staff to.
-- ----------------------------------------------------------------------------
CREATE TABLE Clients (
    ClientID       INT AUTO_INCREMENT PRIMARY KEY,
    ClientName     VARCHAR(150) NOT NULL UNIQUE,
    ContactPerson  VARCHAR(150) NULL,
    ContactEmail   VARCHAR(150) NULL,
    ContractStart  DATE         NULL,
    ContractEnd    DATE         NULL,
    Status         VARCHAR(20)  NOT NULL DEFAULT 'Active',
    CONSTRAINT CHK_Clients_Status   CHECK (Status IN ('Prospect', 'Active', 'On Hold', 'Contract Ended')),
    CONSTRAINT CHK_Clients_Contract CHECK (ContractEnd IS NULL OR ContractEnd >= ContractStart)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 6: ClientSites
-- Staff are posted to a site, not to a client as a whole, because one client
-- may have several premises. GuardsRequired is the agreed strength.
-- ----------------------------------------------------------------------------
CREATE TABLE ClientSites (
    SiteID          INT AUTO_INCREMENT PRIMARY KEY,
    ClientID        INT          NOT NULL,
    SiteName        VARCHAR(150) NOT NULL,
    City            VARCHAR(80)  NULL,
    GuardsRequired  INT          NOT NULL DEFAULT 0,
    Status          VARCHAR(20)  NOT NULL DEFAULT 'Active',
    CONSTRAINT FK_Sites_Clients FOREIGN KEY (ClientID)
        REFERENCES Clients(ClientID) ON DELETE CASCADE,
    CONSTRAINT UQ_Sites_ClientName UNIQUE (ClientID, SiteName),
    CONSTRAINT CHK_Sites_Guards CHECK (GuardsRequired >= 0),
    CONSTRAINT CHK_Sites_Status CHECK (Status IN ('Active', 'On Hold', 'Closed'))
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 7: Employees
-- The central record. LineManagerID is a self-referencing foreign key.
-- Leavers are never deleted: their status changes and an exit date is set,
-- so their history and documents stay available.
-- The national ID number is encrypted by the application before insert and
-- stored as VARBINARY. NINHash allows duplicate checks without decrypting,
-- and NINLast4 is kept for display only.
-- ----------------------------------------------------------------------------
CREATE TABLE Employees (
    EmployeeID        INT AUTO_INCREMENT PRIMARY KEY,
    StaffNumber       VARCHAR(12)    NOT NULL UNIQUE,
    FirstName         VARCHAR(80)    NOT NULL,
    LastName          VARCHAR(80)    NOT NULL,
    Gender            VARCHAR(10)    NULL,
    DateOfBirth       DATE           NULL,
    Email             VARCHAR(150)   NULL,
    PhoneNumber       VARCHAR(20)    NULL,
    NIN               VARBINARY(256) NULL,
    NINHash           CHAR(64)       NULL,
    NINLast4          CHAR(4)        NULL,
    PositionID        INT            NOT NULL,
    LineManagerID     INT            NULL,
    JoiningDate       DATE           NOT NULL,
    EmploymentType    VARCHAR(20)    NOT NULL DEFAULT 'Full Time',
    EmploymentStatus  VARCHAR(20)    NOT NULL DEFAULT 'Active',
    ExitDate          DATE           NULL,
    ExitReason        VARCHAR(500)   NULL,
    CreatedAt         DATETIME       NOT NULL DEFAULT (UTC_TIMESTAMP()),
    CONSTRAINT FK_Employees_Positions   FOREIGN KEY (PositionID)    REFERENCES Positions(PositionID),
    CONSTRAINT FK_Employees_LineManager FOREIGN KEY (LineManagerID) REFERENCES Employees(EmployeeID),
    CONSTRAINT CHK_Employees_Gender CHECK (Gender IN ('Male', 'Female') OR Gender IS NULL),
    CONSTRAINT CHK_Employees_Email  CHECK (Email LIKE '%_@__%.__%' OR Email IS NULL),
    CONSTRAINT CHK_Employees_Type   CHECK (EmploymentType IN ('Full Time', 'Part Time', 'Contract', 'Probation')),
    CONSTRAINT CHK_Employees_Status CHECK (EmploymentStatus IN
        ('Active', 'On Leave', 'Suspended', 'Resigned', 'Retired', 'Terminated', 'Contract Ended')),
    -- A leaver must have an exit date; a current employee must not.
    CONSTRAINT CHK_Employees_Exit CHECK (
        (EmploymentStatus IN ('Resigned', 'Retired', 'Terminated', 'Contract Ended') AND ExitDate IS NOT NULL)
        OR
        (EmploymentStatus IN ('Active', 'On Leave', 'Suspended') AND ExitDate IS NULL)
    ),
    CONSTRAINT CHK_Employees_ExitAfterJoin CHECK (ExitDate IS NULL OR ExitDate >= JoiningDate)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 8: Assignments
-- Which employee is posted to which client site, in what role and shift.
-- EndDate NULL means the posting is current. Old postings are closed, never
-- overwritten, so the full history is kept.
--
-- ONE OPEN POSTING PER EMPLOYEE
--   MySQL has no filtered unique index, so OpenAssignment is a stored
--   generated column that holds the EmployeeID only while the posting is
--   open, and NULL once it ends. A UNIQUE index on it allows any number of
--   closed postings (NULLs) but only one open posting per employee.
--
-- NO CASCADE ON EmployeeID
--   MySQL does not allow ON DELETE CASCADE on a column used by a stored
--   generated column. This is also deliberate: deleting an employee who has
--   posting history fails, instead of silently destroying that history.
-- ----------------------------------------------------------------------------
CREATE TABLE Assignments (
    AssignmentID    INT AUTO_INCREMENT PRIMARY KEY,
    EmployeeID      INT          NOT NULL,
    SiteID          INT          NOT NULL,
    AssignmentRole  VARCHAR(50)  NOT NULL,
    ShiftType       VARCHAR(20)  NULL,
    VehicleRegNo    VARCHAR(20)  NULL,
    PrincipalName   VARCHAR(150) NULL,
    StartDate       DATE         NOT NULL,
    EndDate         DATE         NULL,
    EndReason       VARCHAR(255) NULL,
    OpenAssignment  INT GENERATED ALWAYS AS
        (CASE WHEN EndDate IS NULL THEN EmployeeID ELSE NULL END) STORED,
    CONSTRAINT FK_Assignments_Employees FOREIGN KEY (EmployeeID) REFERENCES Employees(EmployeeID),
    CONSTRAINT FK_Assignments_Sites     FOREIGN KEY (SiteID)     REFERENCES ClientSites(SiteID),
    CONSTRAINT UX_Assignments_OneOpen UNIQUE (OpenAssignment),
    CONSTRAINT CHK_Assignments_Shift CHECK (ShiftType IN ('Day', 'Night', 'Rotating', '24 Hours') OR ShiftType IS NULL),
    CONSTRAINT CHK_Assignments_Dates CHECK (EndDate IS NULL OR EndDate >= StartDate),
    -- A vehicle belongs only on a driver's posting, a principal only on a CPO's.
    CONSTRAINT CHK_Assignments_Vehicle   CHECK (VehicleRegNo  IS NULL OR AssignmentRole = 'Driver'),
    CONSTRAINT CHK_Assignments_Principal CHECK (PrincipalName IS NULL OR AssignmentRole = 'CPO')
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 9: Skills
-- ----------------------------------------------------------------------------
CREATE TABLE Skills (
    SkillID    INT AUTO_INCREMENT PRIMARY KEY,
    SkillName  VARCHAR(80) NOT NULL UNIQUE,
    Category   VARCHAR(50) NULL
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 10: EmployeeSkills (junction table, many-to-many)
-- The composite primary key stops the same skill being recorded twice.
-- ----------------------------------------------------------------------------
CREATE TABLE EmployeeSkills (
    EmployeeID        INT         NOT NULL,
    SkillID           INT         NOT NULL,
    ProficiencyLevel  VARCHAR(20) NULL,
    CONSTRAINT PK_EmployeeSkills PRIMARY KEY (EmployeeID, SkillID),
    CONSTRAINT FK_EmployeeSkills_Employees FOREIGN KEY (EmployeeID) REFERENCES Employees(EmployeeID) ON DELETE CASCADE,
    CONSTRAINT FK_EmployeeSkills_Skills    FOREIGN KEY (SkillID)    REFERENCES Skills(SkillID)       ON DELETE CASCADE,
    CONSTRAINT CHK_EmployeeSkills_Level CHECK (ProficiencyLevel IN ('Basic', 'Intermediate', 'Advanced') OR ProficiencyLevel IS NULL)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 11: DocumentTypes
-- Document requirements are stored as data, not code. RequiredCount allows
-- "two guarantor forms". AppliesToCategoryID NULL means everyone; set it to
-- make a document mandatory for one category only (a licence for drivers).
-- ----------------------------------------------------------------------------
CREATE TABLE DocumentTypes (
    DocumentTypeID       INT AUTO_INCREMENT PRIMARY KEY,
    TypeName             VARCHAR(100) NOT NULL UNIQUE,
    IsMandatory          TINYINT(1)   NOT NULL DEFAULT 0,
    RequiredCount        INT          NOT NULL DEFAULT 1,
    HasExpiry            TINYINT(1)   NOT NULL DEFAULT 0,
    AppliesToCategoryID  INT          NULL,
    CONSTRAINT FK_DocTypes_Categories FOREIGN KEY (AppliesToCategoryID) REFERENCES StaffCategories(StaffCategoryID),
    CONSTRAINT CHK_DocTypes_Count CHECK (RequiredCount >= 1)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 12: EmployeeDocuments
-- One row per stored file. The file itself lives on disk; the database keeps
-- the path, a SHA-256 hash to detect tampering, and verification details.
-- The MIME type CHECK means an executable can never be recorded.
-- ----------------------------------------------------------------------------
CREATE TABLE EmployeeDocuments (
    DocumentID          INT AUTO_INCREMENT PRIMARY KEY,
    EmployeeID          INT          NOT NULL,
    DocumentTypeID      INT          NOT NULL,
    StoragePath         VARCHAR(400) NOT NULL UNIQUE,
    MimeType            VARCHAR(100) NOT NULL,
    FileSizeBytes       BIGINT       NOT NULL,
    FileHash            CHAR(64)     NULL,
    ExpiryDate          DATE         NULL,
    VerificationStatus  VARCHAR(20)  NOT NULL DEFAULT 'Pending',
    VerifiedByUserID    INT          NULL,
    UploadedByUserID    INT          NULL,
    UploadedAt          DATETIME     NOT NULL DEFAULT (UTC_TIMESTAMP()),
    CONSTRAINT FK_Documents_Employees  FOREIGN KEY (EmployeeID)       REFERENCES Employees(EmployeeID) ON DELETE CASCADE,
    CONSTRAINT FK_Documents_Types      FOREIGN KEY (DocumentTypeID)   REFERENCES DocumentTypes(DocumentTypeID),
    CONSTRAINT FK_Documents_VerifiedBy FOREIGN KEY (VerifiedByUserID) REFERENCES Users(UserID),
    CONSTRAINT FK_Documents_UploadedBy FOREIGN KEY (UploadedByUserID) REFERENCES Users(UserID),
    CONSTRAINT CHK_Documents_Status CHECK (VerificationStatus IN ('Pending', 'Verified', 'Rejected')),
    CONSTRAINT CHK_Documents_Mime   CHECK (MimeType IN ('application/pdf', 'image/jpeg', 'image/png')),
    CONSTRAINT CHK_Documents_Size   CHECK (FileSizeBytes > 0 AND FileSizeBytes <= 5242880)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 13: Guarantors
-- People who stand as guarantor for an employee, linked to the signed form.
-- RESTRICT stops a signed form being deleted while a guarantor points at it.
-- ----------------------------------------------------------------------------
CREATE TABLE Guarantors (
    GuarantorID         INT AUTO_INCREMENT PRIMARY KEY,
    EmployeeID          INT          NOT NULL,
    FullName            VARCHAR(150) NOT NULL,
    Relationship        VARCHAR(50)  NOT NULL,
    Occupation          VARCHAR(100) NULL,
    PhoneNumber         VARCHAR(20)  NOT NULL,
    FormDocumentID      INT          NULL,
    VerificationStatus  VARCHAR(20)  NOT NULL DEFAULT 'Pending',
    CONSTRAINT FK_Guarantors_Employees FOREIGN KEY (EmployeeID)     REFERENCES Employees(EmployeeID) ON DELETE CASCADE,
    CONSTRAINT FK_Guarantors_Document  FOREIGN KEY (FormDocumentID) REFERENCES EmployeeDocuments(DocumentID) ON DELETE RESTRICT,
    CONSTRAINT CHK_Guarantors_Status CHECK (VerificationStatus IN ('Pending', 'Verified', 'Rejected'))
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 14: EmployeeStatusHistory
-- Employees.EmploymentStatus holds only the current status. This table keeps
-- every period (leave, suspension, exit) with its dates and reason, so the
-- next change never overwrites the last one. EndDate NULL = current period.
-- ----------------------------------------------------------------------------
CREATE TABLE EmployeeStatusHistory (
    StatusHistoryID   INT AUTO_INCREMENT PRIMARY KEY,
    EmployeeID        INT          NOT NULL,
    Status            VARCHAR(20)  NOT NULL,
    StartDate         DATE         NOT NULL,
    EndDate           DATE         NULL,
    Comment           VARCHAR(500) NULL,
    RecordedByUserID  INT          NULL,
    CONSTRAINT FK_StatusHistory_Employees  FOREIGN KEY (EmployeeID)       REFERENCES Employees(EmployeeID) ON DELETE CASCADE,
    CONSTRAINT FK_StatusHistory_RecordedBy FOREIGN KEY (RecordedByUserID) REFERENCES Users(UserID),
    CONSTRAINT CHK_StatusHistory_Status CHECK (Status IN
        ('Active', 'On Leave', 'Suspended', 'Resigned', 'Retired', 'Terminated', 'Contract Ended')),
    CONSTRAINT CHK_StatusHistory_Dates CHECK (EndDate IS NULL OR EndDate >= StartDate)
) ENGINE=InnoDB;

-- ----------------------------------------------------------------------------
-- Table 15: AuditLog
-- Who did what, to which record, and when. Every document view is logged.
-- ----------------------------------------------------------------------------
CREATE TABLE AuditLog (
    AuditID     BIGINT AUTO_INCREMENT PRIMARY KEY,
    UserID      INT           NULL,
    ActionType  VARCHAR(30)   NOT NULL,
    EntityName  VARCHAR(50)   NOT NULL,
    EntityID    INT           NULL,
    Details     VARCHAR(1000) NULL,
    OccurredAt  DATETIME      NOT NULL DEFAULT (UTC_TIMESTAMP()),
    CONSTRAINT FK_AuditLog_Users FOREIGN KEY (UserID) REFERENCES Users(UserID) ON DELETE SET NULL,
    CONSTRAINT CHK_AuditLog_Action CHECK (ActionType IN
        ('Create', 'Update', 'Remove', 'View', 'Download', 'Upload', 'Verify', 'Reject', 'Assign', 'End Assignment', 'Login'))
) ENGINE=InnoDB;


-- ============================================================================
-- SECTION 3: INDEXES
-- ============================================================================
-- Foreign keys and the columns used most for searching and filtering.
-- MySQL allows repeated NULLs in a UNIQUE index, so email and national ID
-- stay unique when recorded but remain optional.

CREATE UNIQUE INDEX UX_Employees_Email  ON Employees(Email);
CREATE UNIQUE INDEX UX_Employees_NIN    ON Employees(NINHash);

CREATE INDEX IX_Employees_Name          ON Employees(LastName, FirstName);
CREATE INDEX IX_Employees_Status        ON Employees(EmploymentStatus);
CREATE INDEX IX_Employees_Position      ON Employees(PositionID);
CREATE INDEX IX_Employees_Manager       ON Employees(LineManagerID);
CREATE INDEX IX_Employees_Joining       ON Employees(JoiningDate);

CREATE INDEX IX_Assignments_Site        ON Assignments(SiteID, EndDate);
CREATE INDEX IX_Assignments_Employee    ON Assignments(EmployeeID, StartDate);

CREATE INDEX IX_Documents_Employee      ON EmployeeDocuments(EmployeeID, DocumentTypeID);
CREATE INDEX IX_Documents_Expiry        ON EmployeeDocuments(ExpiryDate);
CREATE INDEX IX_Documents_Status        ON EmployeeDocuments(VerificationStatus);

CREATE INDEX IX_Guarantors_Employee     ON Guarantors(EmployeeID);
CREATE INDEX IX_StatusHistory_Employee  ON EmployeeStatusHistory(EmployeeID, StartDate);
CREATE INDEX IX_Positions_Category      ON Positions(StaffCategoryID);
CREATE INDEX IX_Sites_Client            ON ClientSites(ClientID);
CREATE INDEX IX_Audit_Entity            ON AuditLog(EntityName, EntityID);
CREATE INDEX IX_Audit_Occurred          ON AuditLog(OccurredAt);


-- ============================================================================
-- SECTION 4: SAMPLE DATA
-- ============================================================================
-- All people, companies and phone numbers are fictional. Phone numbers use
-- the reserved 0800000 range.

INSERT INTO Users (UserID, FullName, Email, PasswordHash, Role) VALUES
(1, 'System Administrator', 'admin@example.com',      '$2b$12$placeholderhashplaceholderhashplaceholderha', 'Admin'),
(2, 'HR Desk',              'hr@example.com',         '$2b$12$placeholderhashplaceholderhashplaceholderhb', 'HR'),
(3, 'Operations Desk',      'operations@example.com', '$2b$12$placeholderhashplaceholderhashplaceholderhc', 'Operations');

INSERT INTO Departments (DepartmentID, DepartmentName, Description) VALUES
(1, 'Operations',             'Deployment and supervision of staff on client sites'),
(2, 'Human Resources',        'Recruitment, records and staff welfare'),
(3, 'Finance',                'Accounts and financial control'),
(4, 'Information Technology', 'Systems and data'),
(5, 'Fleet',                  'Vehicles and drivers');

INSERT INTO StaffCategories (StaffCategoryID, CategoryName, Description, IsDeployed) VALUES
(1, 'Direct Staff', 'Works for the company itself',              0),
(2, 'Guard',        'Security guard posted to a client site',    1),
(3, 'Driver',       'Driver assigned to a client',               1),
(4, 'CPO',          'Close protection officer for a principal',  1);

INSERT INTO Positions (PositionID, PositionTitle, DepartmentID, StaffCategoryID) VALUES
(1, 'Operations Manager',       1, 1),
(2, 'HR Officer',               2, 1),
(3, 'Finance Officer',          3, 1),
(4, 'IT Administrator',         4, 1),
(5, 'Site Supervisor',          1, 1),
(6, 'Security Guard',           1, 2),
(7, 'Client Driver',            5, 3),
(8, 'Close Protection Officer', 1, 4);

INSERT INTO Clients (ClientID, ClientName, ContactPerson, ContactEmail, ContractStart, ContractEnd, Status) VALUES
(1, 'Harbourline Group',  'Bisi Adeyemi', 'bisi@example.com',   '2022-03-01', '2027-02-28', 'Active'),
(2, 'Northgate Retail',   'Chuka Eze',    'chuka@example.com',  '2022-01-15', NULL,         'Active'),
(3, 'Crestway Logistics', 'Halima Yusuf', 'halima@example.com', '2021-04-01', NULL,         'Active');

INSERT INTO ClientSites (SiteID, ClientID, SiteName, City, GuardsRequired) VALUES
(1, 1, 'Harbourline Head Office', 'Lagos', 3),
(2, 1, 'Ikoyi Residence',         'Lagos', 0),
(3, 2, 'Oregun Warehouse',        'Lagos', 2),
(4, 2, 'Victoria Island Office',  'Lagos', 1),
(5, 3, 'Ojota Depot',             'Lagos', 3);

INSERT INTO Employees
  (EmployeeID, StaffNumber, FirstName, LastName, Gender, DateOfBirth, Email, PhoneNumber,
   PositionID, LineManagerID, JoiningDate, EmploymentType, EmploymentStatus, ExitDate, ExitReason)
VALUES
(1,  'EMP-0001', 'Joseph',   'Idoko',      'Male',   '1984-02-11', 'j.idoko@example.com',    '08000000001', 1, NULL, '2019-08-24', 'Full Time', 'Active',     NULL, NULL),
(2,  'EMP-0002', 'Abiola',   'Arinde',     'Female', '1992-07-30', 'a.arinde@example.com',   '08000000002', 2, 1,    '2021-04-05', 'Full Time', 'On Leave',   NULL, NULL),
(3,  'EMP-0003', 'Musa',     'Danjuma',    'Male',   '1986-05-19', 'm.danjuma@example.com',  '08000000003', 5, 1,    '2020-02-10', 'Full Time', 'Active',     NULL, NULL),
(4,  'EMP-0004', 'Kingsley', 'Ossai',      'Male',   '1995-11-02', NULL,                     '08000000004', 6, 3,    '2022-02-11', 'Full Time', 'Active',     NULL, NULL),
(5,  'EMP-0005', 'Grace',    'Adeyinka',   'Female', '1997-05-14', NULL,                     '08000000005', 6, 3,    '2023-01-13', 'Full Time', 'Active',     NULL, NULL),
(6,  'EMP-0006', 'Emmanuel', 'Osha',       'Male',   '1993-08-08', NULL,                     '08000000006', 6, 3,    '2021-04-12', 'Full Time', 'Terminated', '2025-05-30', 'Repeated absence from post after two written warnings'),
(7,  'EMP-0007', 'Ifeanyi',  'Nwachukwu',  'Male',   '1998-01-21', NULL,                     '08000000007', 6, 3,    '2024-03-04', 'Contract',  'Suspended',  NULL, NULL),
(8,  'EMP-0008', 'Samuel',   'Bassey',     'Male',   '1988-03-19', 's.bassey@example.com',   '08000000008', 7, 1,    '2022-06-18', 'Full Time', 'Active',     NULL, NULL),
(9,  'EMP-0009', 'Chinedu',  'Okafor',     'Male',   '1990-01-25', 'c.okafor@example.com',   '08000000009', 8, 1,    '2021-09-04', 'Full Time', 'Active',     NULL, NULL),
(10, 'EMP-0010', 'Fatima',   'Lawal',      'Female', '1999-10-03', NULL,                     '08000000010', 6, 3,    '2025-02-17', 'Probation', 'Active',     NULL, NULL),
(11, 'EMP-0011', 'Tunde',    'Bakare',     'Male',   '1994-12-06', 't.bakare@example.com',   '08000000011', 4, 1,    '2023-07-01', 'Full Time', 'Active',     NULL, NULL),
(12, 'EMP-0012', 'Ngozi',    'Eze',        'Female', '1989-04-27', 'n.eze@example.com',      '08000000012', 3, 1,    '2020-11-02', 'Full Time', 'Resigned',   '2025-12-31', 'Relocated abroad');

-- Postings. Kingsley has one closed and one current posting; Emmanuel's
-- posting was closed on the day he left.
INSERT INTO Assignments
  (AssignmentID, EmployeeID, SiteID, AssignmentRole, ShiftType, VehicleRegNo, PrincipalName, StartDate, EndDate, EndReason)
VALUES
(1, 4,  3, 'Guard',  'Day',      NULL,         NULL,           '2022-02-15', '2024-03-31', 'Redeployed at client request'),
(2, 4,  1, 'Guard',  'Night',    NULL,         NULL,           '2024-04-01', NULL,         NULL),
(3, 5,  4, 'Guard',  'Day',      NULL,         NULL,           '2023-01-20', NULL,         NULL),
(4, 6,  5, 'Guard',  'Night',    NULL,         NULL,           '2021-04-20', '2025-05-30', 'Employee terminated'),
(5, 7,  5, 'Guard',  'Day',      NULL,         NULL,           '2024-03-10', NULL,         NULL),
(6, 8,  3, 'Driver', 'Day',      'LSR-472-XA', NULL,           '2022-06-20', NULL,         NULL),
(7, 9,  2, 'CPO',    'Rotating', NULL,         'Mr. T. Harbourline', '2021-09-10', NULL,   NULL),
(8, 10, 1, 'Guard',  'Day',      NULL,         NULL,           '2025-02-20', NULL,         NULL),
(9, 5,  5, 'Guard',  'Night',    NULL,         NULL,           '2023-01-16', '2023-01-19', 'Induction cover only');

INSERT INTO Skills (SkillID, SkillName, Category) VALUES
(1, 'Access Control',    'Security'),
(2, 'CCTV Monitoring',   'Security'),
(3, 'First Aid',         'Safety'),
(4, 'Defensive Driving', 'Driving'),
(5, 'Close Protection',  'Security'),
(6, 'Report Writing',    'Administration');

INSERT INTO EmployeeSkills (EmployeeID, SkillID, ProficiencyLevel) VALUES
(3, 6, 'Advanced'),     (3, 1, 'Advanced'),
(4, 1, 'Advanced'),     (4, 3, 'Intermediate'),
(5, 2, 'Intermediate'), (5, 1, 'Basic'),
(7, 1, 'Basic'),
(8, 4, 'Advanced'),     (8, 3, 'Basic'),
(9, 5, 'Advanced'),     (9, 4, 'Intermediate'),
(10, 2, 'Basic');

INSERT INTO DocumentTypes (DocumentTypeID, TypeName, IsMandatory, RequiredCount, HasExpiry, AppliesToCategoryID) VALUES
(1, 'Signed Offer Letter',     1, 1, 0, NULL),
(2, 'Guarantor Form',          1, 2, 0, NULL),
(3, 'Means of Identification', 1, 1, 1, NULL),
(4, 'Driving Licence',         1, 1, 1, 3),
(5, 'Training Certificate',    0, 1, 1, NULL);

INSERT INTO EmployeeDocuments
  (DocumentID, EmployeeID, DocumentTypeID, StoragePath, MimeType, FileSizeBytes, ExpiryDate, VerificationStatus, VerifiedByUserID, UploadedByUserID)
VALUES
-- Joseph: complete
(1,  1, 1, 'EMP-0001/offer-letter.pdf',  'application/pdf', 182000, NULL,         'Verified', 2, 2),
(2,  1, 2, 'EMP-0001/guarantor-1.pdf',   'application/pdf', 240000, NULL,         'Verified', 2, 2),
(3,  1, 2, 'EMP-0001/guarantor-2.pdf',   'application/pdf', 236000, NULL,         'Verified', 2, 2),
(4,  1, 3, 'EMP-0001/national-id.jpg',   'image/jpeg',      410000, '2029-03-01', 'Verified', 2, 2),
-- Abiola: guarantors missing
(5,  2, 1, 'EMP-0002/offer-letter.pdf',  'application/pdf', 175000, NULL,         'Verified', 1, 2),
(6,  2, 3, 'EMP-0002/passport.jpg',      'image/jpeg',      390000, '2030-06-15', 'Verified', 1, 2),
-- Musa: complete
(7,  3, 1, 'EMP-0003/offer-letter.pdf',  'application/pdf', 181000, NULL,         'Verified', 2, 2),
(8,  3, 2, 'EMP-0003/guarantor-1.pdf',   'application/pdf', 228000, NULL,         'Verified', 2, 2),
(9,  3, 2, 'EMP-0003/guarantor-2.pdf',   'application/pdf', 231000, NULL,         'Verified', 2, 2),
(10, 3, 3, 'EMP-0003/national-id.jpg',   'image/jpeg',      402000, '2028-08-20', 'Verified', 2, 2),
-- Kingsley: complete, plus a training certificate
(11, 4, 1, 'EMP-0004/offer-letter.pdf',  'application/pdf', 179000, NULL,         'Verified', 2, 3),
(12, 4, 2, 'EMP-0004/guarantor-1.pdf',   'application/pdf', 244000, NULL,         'Verified', 2, 3),
(13, 4, 2, 'EMP-0004/guarantor-2.pdf',   'application/pdf', 239000, NULL,         'Verified', 2, 3),
(14, 4, 3, 'EMP-0004/voters-card.png',   'image/png',       355000, '2027-05-01', 'Verified', 2, 3),
(15, 4, 5, 'EMP-0004/training.pdf',      'application/pdf', 120000, '2026-11-30', 'Verified', 2, 3),
-- Grace: only one guarantor form so far, ID expiring soon
(16, 5, 1, 'EMP-0005/offer-letter.pdf',  'application/pdf', 177000, NULL,         'Verified', 2, 3),
(17, 5, 2, 'EMP-0005/guarantor-1.pdf',   'application/pdf', 233000, NULL,         'Verified', 2, 3),
(18, 5, 3, 'EMP-0005/national-id.jpg',   'image/jpeg',      398000, '2026-11-20', 'Verified', 2, 3),
-- Ifeanyi: ID not yet verified, no guarantors
(19, 7, 1, 'EMP-0007/offer-letter.pdf',  'application/pdf', 176000, NULL,         'Verified', 2, 3),
(20, 7, 3, 'EMP-0007/national-id.jpg',   'image/jpeg',      401000, '2028-01-10', 'Pending',  NULL, 3),
-- Samuel: complete, driving licence expiring soon
(21, 8, 1, 'EMP-0008/offer-letter.pdf',  'application/pdf', 180000, NULL,         'Verified', 2, 3),
(22, 8, 2, 'EMP-0008/guarantor-1.pdf',   'application/pdf', 238000, NULL,         'Verified', 2, 3),
(23, 8, 2, 'EMP-0008/guarantor-2.pdf',   'application/pdf', 241000, NULL,         'Verified', 2, 3),
(24, 8, 3, 'EMP-0008/national-id.jpg',   'image/jpeg',      405000, '2028-02-14', 'Verified', 2, 3),
(25, 8, 4, 'EMP-0008/licence.jpg',       'image/jpeg',      330000, '2026-12-01', 'Verified', 2, 3),
-- Chinedu: complete
(26, 9, 1, 'EMP-0009/offer-letter.pdf',  'application/pdf', 178000, NULL,         'Verified', 2, 3),
(27, 9, 2, 'EMP-0009/guarantor-1.pdf',   'application/pdf', 235000, NULL,         'Verified', 2, 3),
(28, 9, 2, 'EMP-0009/guarantor-2.pdf',   'application/pdf', 237000, NULL,         'Verified', 2, 3),
(29, 9, 3, 'EMP-0009/passport.jpg',      'image/jpeg',      388000, '2031-09-30', 'Verified', 2, 3),
-- Fatima: offer letter awaiting verification
(30, 10, 1, 'EMP-0010/offer-letter.pdf', 'application/pdf', 174000, NULL,         'Pending',  NULL, 3),
-- Tunde: guarantors missing
(31, 11, 1, 'EMP-0011/offer-letter.pdf', 'application/pdf', 183000, NULL,         'Verified', 2, 2),
(32, 11, 3, 'EMP-0011/national-id.jpg',  'image/jpeg',      399000, '2029-12-12', 'Verified', 2, 2);

INSERT INTO Guarantors (EmployeeID, FullName, Relationship, Occupation, PhoneNumber, FormDocumentID, VerificationStatus) VALUES
(1, 'Grace Idoko',     'Spouse',  'Teacher',       '08000000101', 2,    'Verified'),
(1, 'Paul Ameh',       'Friend',  'Civil Servant', '08000000102', 3,    'Verified'),
(3, 'Hauwa Danjuma',   'Spouse',  'Nurse',         '08000000103', 8,    'Verified'),
(3, 'Ibrahim Sule',    'Cousin',  'Trader',        '08000000104', 9,    'Verified'),
(4, 'Peter Ossai',     'Father',  'Trader',        '08000000105', 12,   'Verified'),
(4, 'Rita Okonkwo',    'Aunt',    'Banker',        '08000000106', 13,   'Verified'),
(5, 'Samuel Adeyinka', 'Father',  'Retired',       '08000000107', 17,   'Verified'),
(5, 'Bola Adeyinka',   'Brother', 'Engineer',      '08000000108', NULL, 'Pending'),
(8, 'Ime Bassey',      'Brother', 'Teacher',       '08000000109', 22,   'Verified'),
(8, 'Eno Bassey',      'Spouse',  'Accountant',    '08000000110', 23,   'Verified'),
(9, 'Adaeze Okafor',   'Sister',  'Pharmacist',    '08000000111', 27,   'Verified'),
(9, 'Kelechi Obi',     'Friend',  'Lawyer',        '08000000112', 28,   'Verified');

INSERT INTO EmployeeStatusHistory (EmployeeID, Status, StartDate, EndDate, Comment, RecordedByUserID) VALUES
(1,  'Active',     '2019-08-24', NULL,         'Joined', 2),
(2,  'Active',     '2021-04-05', '2026-09-30', 'Joined', 2),
(2,  'On Leave',   '2026-10-01', '2026-10-31', 'Annual leave', 2),
(3,  'Active',     '2020-02-10', NULL,         'Joined', 2),
(4,  'Active',     '2022-02-11', '2023-06-04', 'Joined', 2),
(4,  'On Leave',   '2023-06-05', '2023-06-18', 'Annual leave', 2),
(4,  'Active',     '2023-06-19', NULL,         'Returned from leave', 2),
(5,  'Active',     '2023-01-13', NULL,         'Joined', 2),
(6,  'Active',     '2021-04-12', '2024-11-03', 'Joined', 2),
(6,  'Suspended',  '2024-11-04', '2024-11-17', 'First written warning: absence from post', 3),
(6,  'Active',     '2024-11-18', '2025-05-29', 'Returned from suspension', 2),
(6,  'Terminated', '2025-05-30', NULL,         'Second written warning: absence from post', 2),
(7,  'Active',     '2024-03-04', '2026-09-14', 'Joined', 2),
(7,  'Suspended',  '2026-09-15', '2026-10-15', 'Pending investigation', 3),
(8,  'Active',     '2022-06-18', NULL,         'Joined', 2),
(9,  'Active',     '2021-09-04', NULL,         'Joined', 2),
(10, 'Active',     '2025-02-17', NULL,         'Joined', 2),
(11, 'Active',     '2023-07-01', NULL,         'Joined', 2),
(12, 'Active',     '2020-11-02', '2025-12-30', 'Joined', 2),
(12, 'Resigned',   '2025-12-31', NULL,         'Relocated abroad', 2);

INSERT INTO AuditLog (UserID, ActionType, EntityName, EntityID, Details, OccurredAt) VALUES
(2, 'Upload', 'EmployeeDocuments', 18, 'Uploaded national ID for EMP-0005',          '2026-09-02 09:14:00'),
(2, 'Verify', 'EmployeeDocuments', 18, 'Verified national ID for EMP-0005',          '2026-09-02 11:40:00'),
(3, 'Assign', 'Assignments',        8, 'Posted EMP-0010 to Harbourline Head Office', '2026-09-05 08:02:00'),
(3, 'Update', 'Employees',          7, 'Status changed to Suspended',                '2026-09-15 16:25:00'),
(1, 'View',   'EmployeeDocuments', 20, 'Viewed national ID for EMP-0007',            '2026-09-16 10:03:00'),
(2, 'View',   'EmployeeDocuments', 20, 'Viewed national ID for EMP-0007',            '2026-09-16 10:47:00');


-- ============================================================================
-- SECTION 5: VIEWS
-- ============================================================================
-- Derived values are calculated here rather than stored on the tables.

-- ----------------------------------------------------------------------------
-- View 1: vw_EmployeeDirectory
-- Every employee with their position, department, category and current
-- posting. The LEFT JOINs keep employees who are not posted anywhere.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_EmployeeDirectory AS
SELECT
    e.EmployeeID,
    e.StaffNumber,
    CONCAT(e.FirstName, ' ', e.LastName)          AS FullName,
    e.EmploymentStatus,
    e.JoiningDate,
    TIMESTAMPDIFF(YEAR, e.JoiningDate, CURDATE()) AS YearsOfService,
    p.PositionTitle,
    d.DepartmentName,
    sc.CategoryName                               AS StaffCategory,
    CONCAT(m.FirstName, ' ', m.LastName)          AS LineManager,
    c.ClientName                                  AS CurrentClient,
    s.SiteName                                    AS CurrentSite,
    a.ShiftType                                   AS CurrentShift
FROM Employees e
JOIN Positions p          ON p.PositionID       = e.PositionID
JOIN Departments d        ON d.DepartmentID     = p.DepartmentID
JOIN StaffCategories sc   ON sc.StaffCategoryID = p.StaffCategoryID
LEFT JOIN Employees m     ON m.EmployeeID       = e.LineManagerID
LEFT JOIN Assignments a   ON a.EmployeeID       = e.EmployeeID AND a.EndDate IS NULL
LEFT JOIN ClientSites s   ON s.SiteID           = a.SiteID
LEFT JOIN Clients c       ON c.ClientID         = s.ClientID;

-- ----------------------------------------------------------------------------
-- View 2: vw_DocumentCompliance
-- For each current employee and each mandatory document that applies to
-- them, how many verified copies are held against how many are required.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_DocumentCompliance AS
SELECT
    e.EmployeeID,
    e.StaffNumber,
    CONCAT(e.FirstName, ' ', e.LastName) AS FullName,
    sc.CategoryName                      AS StaffCategory,
    dt.TypeName,
    dt.RequiredCount,
    COUNT(ed.DocumentID)                 AS VerifiedCount,
    (COUNT(ed.DocumentID) >= dt.RequiredCount) AS IsSatisfied
FROM Employees e
JOIN Positions p        ON p.PositionID = e.PositionID
JOIN StaffCategories sc ON sc.StaffCategoryID = p.StaffCategoryID
JOIN DocumentTypes dt   ON dt.IsMandatory = 1
                       AND (dt.AppliesToCategoryID IS NULL OR dt.AppliesToCategoryID = sc.StaffCategoryID)
LEFT JOIN EmployeeDocuments ed
       ON ed.EmployeeID = e.EmployeeID
      AND ed.DocumentTypeID = dt.DocumentTypeID
      AND ed.VerificationStatus = 'Verified'
WHERE e.EmploymentStatus IN ('Active', 'On Leave', 'Suspended')
GROUP BY e.EmployeeID, e.StaffNumber, e.FirstName, e.LastName,
         sc.CategoryName, dt.DocumentTypeID, dt.TypeName, dt.RequiredCount;

-- ----------------------------------------------------------------------------
-- View 3: vw_SiteStaffing
-- Guards currently posted to each site against the number the client needs.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_SiteStaffing AS
SELECT
    c.ClientName,
    s.SiteName,
    s.GuardsRequired,
    COUNT(a.AssignmentID)                    AS GuardsPosted,
    s.GuardsRequired - COUNT(a.AssignmentID) AS Shortfall
FROM ClientSites s
JOIN Clients c ON c.ClientID = s.ClientID
LEFT JOIN Assignments a
       ON a.SiteID = s.SiteID
      AND a.EndDate IS NULL
      AND a.AssignmentRole = 'Guard'
WHERE s.Status = 'Active'
GROUP BY c.ClientName, s.SiteID, s.SiteName, s.GuardsRequired;


-- ============================================================================
-- SECTION 6: QUERIES
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Query 1: Who is posted where right now? (multi-table INNER JOIN)
-- ----------------------------------------------------------------------------
SELECT
    c.ClientName,
    s.SiteName,
    e.StaffNumber,
    CONCAT(e.FirstName, ' ', e.LastName) AS Employee,
    a.AssignmentRole,
    a.ShiftType,
    a.StartDate
FROM Assignments a
JOIN Employees e   ON e.EmployeeID = a.EmployeeID
JOIN ClientSites s ON s.SiteID     = a.SiteID
JOIN Clients c     ON c.ClientID   = s.ClientID
WHERE a.EndDate IS NULL
ORDER BY c.ClientName, s.SiteName;

-- ----------------------------------------------------------------------------
-- Query 2: Which sites are short of guards? (LEFT JOIN, GROUP BY, HAVING)
-- ----------------------------------------------------------------------------
SELECT
    c.ClientName,
    s.SiteName,
    s.GuardsRequired,
    COUNT(a.AssignmentID) AS GuardsPosted
FROM ClientSites s
JOIN Clients c ON c.ClientID = s.ClientID
LEFT JOIN Assignments a
       ON a.SiteID = s.SiteID
      AND a.EndDate IS NULL
      AND a.AssignmentRole = 'Guard'
GROUP BY c.ClientName, s.SiteID, s.SiteName, s.GuardsRequired
HAVING COUNT(a.AssignmentID) < s.GuardsRequired
ORDER BY (s.GuardsRequired - COUNT(a.AssignmentID)) DESC;

-- ----------------------------------------------------------------------------
-- Query 3: Which current staff are missing mandatory documents?
-- ----------------------------------------------------------------------------
SELECT StaffNumber, FullName, StaffCategory, TypeName, VerifiedCount, RequiredCount
FROM vw_DocumentCompliance
WHERE IsSatisfied = 0
ORDER BY StaffNumber, TypeName;

-- ----------------------------------------------------------------------------
-- Query 4: Staff deployed to a client site without two verified guarantors
-- (LEFT JOIN so staff with no guarantors at all still appear)
-- ----------------------------------------------------------------------------
SELECT
    e.StaffNumber,
    CONCAT(e.FirstName, ' ', e.LastName) AS Employee,
    s.SiteName,
    COUNT(g.GuarantorID)                 AS VerifiedGuarantors
FROM Employees e
JOIN Assignments a  ON a.EmployeeID = e.EmployeeID AND a.EndDate IS NULL
JOIN ClientSites s  ON s.SiteID     = a.SiteID
LEFT JOIN Guarantors g
       ON g.EmployeeID = e.EmployeeID
      AND g.VerificationStatus = 'Verified'
GROUP BY e.EmployeeID, e.StaffNumber, e.FirstName, e.LastName, s.SiteName
HAVING COUNT(g.GuarantorID) < 2;

-- ----------------------------------------------------------------------------
-- Query 5: Posting history with the previous site for each move
-- (window function LAG)
-- ----------------------------------------------------------------------------
SELECT
    e.StaffNumber,
    CONCAT(e.FirstName, ' ', e.LastName)                                  AS Employee,
    s.SiteName,
    a.StartDate,
    a.EndDate,
    LAG(s.SiteName) OVER (PARTITION BY a.EmployeeID ORDER BY a.StartDate) AS PreviousSite,
    DATEDIFF(COALESCE(a.EndDate, CURDATE()), a.StartDate)                 AS DaysOnSite
FROM Assignments a
JOIN Employees e   ON e.EmployeeID = a.EmployeeID
JOIN ClientSites s ON s.SiteID     = a.SiteID
ORDER BY e.StaffNumber, a.StartDate;

-- ----------------------------------------------------------------------------
-- Query 6: Each line manager and the people who report to them (SELF JOIN)
-- ----------------------------------------------------------------------------
SELECT
    CONCAT(m.FirstName, ' ', m.LastName) AS LineManager,
    COUNT(e.EmployeeID)                  AS DirectReports,
    GROUP_CONCAT(CONCAT(e.FirstName, ' ', e.LastName) ORDER BY e.LastName SEPARATOR ', ') AS ReportNames
FROM Employees m
JOIN Employees e ON e.LineManagerID = m.EmployeeID
WHERE e.EmploymentStatus IN ('Active', 'On Leave', 'Suspended')
GROUP BY m.EmployeeID, m.FirstName, m.LastName
ORDER BY DirectReports DESC;

-- ----------------------------------------------------------------------------
-- Query 7: Headcount by department and category with subtotals (WITH ROLLUP)
-- ----------------------------------------------------------------------------
SELECT
    COALESCE(d.DepartmentName, 'ALL DEPARTMENTS') AS Department,
    COALESCE(sc.CategoryName,  'All categories')  AS Category,
    COUNT(*)                                      AS Headcount
FROM Employees e
JOIN Positions p        ON p.PositionID       = e.PositionID
JOIN Departments d      ON d.DepartmentID     = p.DepartmentID
JOIN StaffCategories sc ON sc.StaffCategoryID = p.StaffCategoryID
WHERE e.EmploymentStatus IN ('Active', 'On Leave', 'Suspended')
GROUP BY d.DepartmentName, sc.CategoryName WITH ROLLUP;

-- ----------------------------------------------------------------------------
-- Query 8: Longest-serving employee in each department (CTE + RANK)
-- ----------------------------------------------------------------------------
WITH Tenure AS (
    SELECT
        d.DepartmentName,
        CONCAT(e.FirstName, ' ', e.LastName) AS Employee,
        e.JoiningDate,
        RANK() OVER (PARTITION BY d.DepartmentID ORDER BY e.JoiningDate) AS TenureRank
    FROM Employees e
    JOIN Positions p   ON p.PositionID   = e.PositionID
    JOIN Departments d ON d.DepartmentID = p.DepartmentID
    WHERE e.EmploymentStatus IN ('Active', 'On Leave', 'Suspended')
)
SELECT DepartmentName, Employee, JoiningDate
FROM Tenure
WHERE TenureRank = 1
ORDER BY JoiningDate;

-- ----------------------------------------------------------------------------
-- Query 9: Documents expired or expiring in the next 90 days
-- ----------------------------------------------------------------------------
SELECT
    e.StaffNumber,
    CONCAT(e.FirstName, ' ', e.LastName)  AS Employee,
    dt.TypeName,
    ed.ExpiryDate,
    DATEDIFF(ed.ExpiryDate, CURDATE())    AS DaysRemaining
FROM EmployeeDocuments ed
JOIN Employees e      ON e.EmployeeID      = ed.EmployeeID
JOIN DocumentTypes dt ON dt.DocumentTypeID = ed.DocumentTypeID
WHERE ed.ExpiryDate <= DATE_ADD(CURDATE(), INTERVAL 90 DAY)
  AND e.EmploymentStatus IN ('Active', 'On Leave', 'Suspended')
ORDER BY ed.ExpiryDate;

-- ----------------------------------------------------------------------------
-- Query 10: Full status timeline for one employee
-- ----------------------------------------------------------------------------
SELECT
    e.StaffNumber,
    h.Status,
    h.StartDate,
    h.EndDate,
    h.Comment,
    u.FullName AS RecordedBy
FROM EmployeeStatusHistory h
JOIN Employees e  ON e.EmployeeID = h.EmployeeID
LEFT JOIN Users u ON u.UserID     = h.RecordedByUserID
WHERE e.StaffNumber = 'EMP-0006'
ORDER BY h.StartDate;

-- ----------------------------------------------------------------------------
-- Query 11: Who has viewed a sensitive document? (audit trail join)
-- ----------------------------------------------------------------------------
SELECT
    al.OccurredAt,
    u.FullName  AS ViewedBy,
    u.Role,
    al.Details
FROM AuditLog al
JOIN Users u ON u.UserID = al.UserID
WHERE al.EntityName = 'EmployeeDocuments'
  AND al.ActionType = 'View'
ORDER BY al.OccurredAt;
