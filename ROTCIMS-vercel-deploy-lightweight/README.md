# ROTCIMS — Reserve Officers' Training Corps Information and Management System

**Target Organization:** San Enrique ROTC Unit  
**Technology Stack:** Pure HTML5, CSS3, Vanilla JavaScript, and Supabase Backend (PostgreSQL + Auth + Storage)  
**Hosting Target:** Vercel Static Hosting  
**Mobile Companion:** Android Mobile Application (.apk)

---

## 📁 System Architecture & File Directory

```
ROTCIMS/
├── index.html                   ← Public Portal / Homepage (Announcements, Overview)
├── login.html                   ← Unified Sign-In Portal (Cadet, Personnel, Admin)
├── register.html                ← Cadet Enlistment Registration Form
├── cadet-dashboard.html         ← Cadet Portal (Digital ID, Live QR Code, Attendance History)
├── admin-dashboard.html         ← Command Staff Overview Dashboard
├── admin-qr-scanner.html        ← Camera QR Scanner (Real-Time Attendance Marking)
├── admin-attendance.html        ← Attendance Records & Manual Input Management
├── admin-reports.html           ← Formation Ledger & Official CSV/Print Reports
├── admin-cadets.html            ← Cadet Directory & Approval Governance
├── admin-personnel.html         ← ROTC Personnel & Officer Assignments
├── admin-announcements.html     ← Unit Directives & Announcements Management
├── admin-documents.html         ← Official Documents & Storage Repository
├── admin-accounts.html          ← User Accounts & Role Administration
├── admin-settings.html          ← Unit Branding & System Settings
│
├── css/
│   ├── style.css                ← Master Military Design System & Typography
│   └── responsive.css           ← Mobile & Tablet Responsive Viewports
│
├── js/
│   ├── config.js                ← Supabase Client CDN Initialization
│   └── auth.js                  ← Session Recovery, Login, Role-Based Route Guards
│
├── assets/
│   ├── logo.png                 ← Official ROTC Unit Insignia
│   └── icon.png                 ← Application Icon
│
├── downloads/
│   └── san-enrique-rotc.apk     ← Android Release APK File
│
├── sql/
│   ├── migration_all_in_one.sql ← Consolidated Database & RLS Migration
│   └── supabase_schema.sql      ← Authoritative PostgreSQL Schema
│
├── vercel.json                  ← Static Hosting Deployment Configuration
└── .env.example                 ← Environment Variables Reference
```

---

## 🚀 How to Run Locally

### Method 1: Direct File Opening
You can simply double-click **`index.html`** or **`login.html`** in any web browser (Google Chrome, Microsoft Edge, Firefox). The Supabase SDK and QR tools are loaded via high-speed CDNs.

### Method 2: Local HTTP Server (Recommended)
Using Python:
```bash
cd C:\Users\princ\Documents\ROTCIMS
python -m http.server 3000
```
Then visit `http://localhost:3000` in your browser.

Using VS Code:
Right-click `index.html` and click **"Open with Live Server"**.

---

## 🌐 How to Deploy to Vercel

1. Push this `ROTCIMS` folder to your GitHub repository.
2. In [Vercel](https://vercel.com), click **"Add New Project"** and import the repository.
3. No build command is required (static HTML/CSS/JS).
4. Click **Deploy**. Vercel will instantly publish the site with free SSL (`https://...`).

---

## 🔒 Security & Multi-Role Governance

1. **Cadet (`cadet`)**: Access restricted to `cadet-dashboard.html`. Can view own profile, generate own QR code, check personal attendance history, and download public documents.
2. **ROTC Personnel (`personnel` / `platoon_leader`)**: Can view all cadet rosters, operate live QR scanner, record manual attendance, publish announcements, and generate attendance reports.
3. **Administrator (`admin`)**: Full command access, including user accounts, role elevation, system settings, and record modifications.

