// ==========================================================================
// FILE: auth.js
// PURPOSE: Provides a centralized Auth object with all authentication and
//          access-control helpers used across ROTCIMS. Every protected page
//          calls Auth.requireAuth() at load time to verify the visitor is
//          logged in and has the correct role before rendering any content.
//
// USED BY:
//   • login.html          — calls Auth.login()
//   • register.html       — calls Auth.register()
//   • cadet-dashboard.html and all cadet pages  — Auth.requireAuth(['cadet'])
//   • admin-dashboard.html and all admin pages  — Auth.requireAuth(['admin'])
//   • platoon_leader pages — Auth.requireAuth(['platoon_leader'])
//   • Any page with a sidebar/topbar — Auth.updateUI() populates name/role badges
//
// DEPENDS ON: config.js (must be loaded first to set up window.supabaseClient)
//
// LOAD ORDER IN HTML:
//   <script src="js/config.js"></script>   ← 1st: creates the Supabase client
//   <script src="js/auth.js"></script>     ← 2nd: Auth object becomes available
//   <script src="js/page-specific.js"></script> ← 3rd: page calls Auth methods
//
// ============================================================
// SECURITY MODEL — IMPORTANT FOR DEVELOPERS TO UNDERSTAND
// ============================================================
//   This file implements CLIENT-SIDE route guards. That means:
//   • They redirect unauthorized users away from a page's HTML/JS.
//   • They do NOT protect the raw data in the database.
//
//   Database-level security is enforced by Supabase Row-Level Security
//   (RLS) policies. Even if a malicious user bypassed these JS guards,
//   the database would still refuse to return data they aren't allowed
//   to see. Always treat JS guards as a UX layer, not the final defense.
//
//   Role values currently used in the system:
//     'cadet'          — Regular enrolled ROTC student
//     'platoon_leader' — Senior cadet with limited admin capability
//     'admin'          — ROTC command staff with full system access
//     'pending'        — Default status after registration; awaiting approval
// ==========================================================================

// --------------------------------------------------------------------------
// SECTION 1 — The Auth Object
// --------------------------------------------------------------------------
// All authentication logic is grouped inside a single plain object called
// `Auth`. This is a common JavaScript pattern (sometimes called the "module
// pattern" or "namespace pattern") that keeps related functions together and
// prevents global namespace pollution. Each property is an async function
// because Supabase API calls involve network requests (they return Promises).
// --------------------------------------------------------------------------

const Auth = {

  // ========================================================================
  // METHOD: getSession()
  // ========================================================================
  // Retrieves the currently active authentication session from the Supabase
  // client. The session object contains the user's access token, refresh
  // token, and basic user info (user.id, user.email, etc.).
  //
  // Returns: The session object if the user is logged in, or null if not.
  //
  // WHY THIS EXISTS:
  //   Supabase stores the session in localStorage (because we set
  //   persistSession: true in config.js). getSession() reads that stored
  //   session and validates it. We use this as the first step in every
  //   auth check — if there's no valid session, the user isn't logged in.
  // ========================================================================
  async getSession() {
    // Destructuring assignment pulls `session` from the nested response object.
    // Supabase always returns { data: { session }, error } from auth methods.
    const { data: { session }, error } = await window.supabaseClient.auth.getSession();

    if (error) {
      // Log to the console for developer debugging. We do NOT throw here
      // because a missing session is a normal "not logged in" state and
      // shouldn't crash the page — we handle it gracefully by returning null.
      console.error("Session error:", error);
      return null;
    }

    // Return the session object (or null if nobody is logged in).
    return session;
  },

  // ========================================================================
  // METHOD: getUser()
  // ========================================================================
  // A convenience wrapper that returns just the user object from the session.
  // The user object contains: id (UUID), email, created_at, etc.
  //
  // Returns: The user object if logged in, or null if not.
  //
  // WHY THIS EXISTS:
  //   Many operations only need the user's ID (e.g., to query the profiles
  //   table). This method saves callers from destructuring the full session.
  // ========================================================================
  async getUser() {
    // Reuse getSession() so the session-reading logic stays in one place
    // (Don't Repeat Yourself — DRY principle).
    const session = await this.getSession();

    // If session is null (user not logged in), return null.
    // If session exists, return its nested user object.
    return session ? session.user : null;
  },

  // ========================================================================
  // METHOD: getProfile()
  // ========================================================================
  // Fetches the user's full profile record from the `public.profiles` table
  // in the Supabase database. This is separate from the auth user because
  // Supabase's auth system only stores login credentials (email, password).
  // All application-specific data (name, role, student ID, etc.) is stored
  // in our custom `profiles` table, linked by the user's UUID.
  //
  // Returns: The profile row as a plain JS object, or null on failure.
  //
  // DATABASE SCHEMA ASSUMED:
  //   Table: profiles
  //   Columns: user_id (FK → auth.users.id), first_name, last_name,
  //            role ('cadet' | 'platoon_leader' | 'admin'),
  //            status ('pending' | 'active' | 'inactive'), ...
  // ========================================================================
  async getProfile() {
    const user = await this.getUser();
    if (!user) return null;

    // 1. Try matching by user_id
    let { data, error } = await window.supabaseClient
      .from("profiles")
      .select("*")
      .eq("user_id", user.id)
      .maybeSingle();

    // 2. Fallback: match by email if user_id was not yet attached
    if (!data && user.email) {
      const emailRes = await window.supabaseClient
        .from("profiles")
        .select("*")
        .eq("email", user.email.toLowerCase())
        .maybeSingle();

      if (emailRes.data) {
        data = emailRes.data;
        // Auto-link user_id for future fast lookups
        if (!data.user_id) {
          await window.supabaseClient
            .from("profiles")
            .update({ user_id: user.id })
            .eq("id", data.id);
          data.user_id = user.id;
        }
      }
    }

    // 3. Fallback: auto-create pending profile row if missing
    if (!data) {
      console.warn("Auto-recovering missing profile for authenticated user:", user.email);
      const meta = user.user_metadata || {};
      const generatedId = "CADET-" + user.id.substring(0, 6).toUpperCase();
      const newProfile = {
        user_id: user.id,
        first_name: meta.first_name || (user.email ? user.email.split('@')[0] : "Cadet"),
        last_name: meta.last_name || "User",
        student_id: meta.student_id || generatedId,
        email: (user.email || "").toLowerCase(),
        role: meta.role || "cadet",
        status: "approved",
        course: "General",
        year_level: "1st Year",
        section: "1",
        date_of_birth: "2000-01-01",
        address: "San Enrique",
        phone: "09000000000"
      };

      try {
        const insertRes = await window.supabaseClient
          .from("profiles")
          .insert(newProfile)
          .select()
          .maybeSingle();

        if (insertRes.data) {
          data = insertRes.data;
        } else if (insertRes.error) {
          console.error("Auto-recovery insert error:", insertRes.error);
        }
      } catch (insertErr) {
        console.error("Auto-recovery exception:", insertErr);
      }
    }

    if (!data && error) {
      console.warn("Profile fetch notice:", error.message);
    }

    return data || null;
  },

  // ========================================================================
  // METHOD: login(email, password)
  // ========================================================================
  // Authenticates an existing user with their email and password using
  // Supabase's built-in email/password auth provider.
  //
  // Parameters:
  //   email    {string} — The user's email address
  //   password {string} — The user's plain-text password (Supabase hashes it)
  //
  // Returns: The auth data object ({ user, session }) on success.
  // Throws:  The Supabase error object on failure (wrong credentials, etc.)
  //
  // WHY THROW INSTEAD OF RETURN NULL?
  //   The login page needs to know exactly what went wrong so it can display
  //   a specific error message to the user (e.g., "Invalid credentials" vs
  //   "Email not confirmed"). Throwing the error lets the calling code catch
  //   it and use error.message directly.
  // ========================================================================
  async login(email, password) {
    const { data, error } = await window.supabaseClient.auth.signInWithPassword({
      // .trim() removes accidental leading/trailing whitespace (common in
      // copy-paste scenarios). .toLowerCase() prevents case-sensitivity issues
      // (e.g., "User@Example.com" and "user@example.com" are treated the same).
      email: email.trim().toLowerCase(),
      password, // Shorthand property — equivalent to `password: password`
    });

    // If Supabase returned an error, re-throw it so the login page's
    // try/catch block can handle it and display a message to the user.
    if (error) throw error;

    // Return the data object which contains { user, session } on success.
    return data;
  },

  // ========================================================================
  // METHOD: register(formData)
  // ========================================================================
  // Registers a brand-new cadet account. This is a TWO-STEP process:
  //   Step 1: Create an auth account in Supabase's auth.users table.
  //   Step 2: Insert a matching profile row in public.profiles.
  //
  // Parameter:
  //   formData {object} — All form field values from the registration form.
  //
  // Returns: The auth data object on success.
  // Throws:  Any error from either step.
  //
  // SECURITY RULES ENFORCED HERE:
  //   • role is ALWAYS hardcoded to 'cadet' — users cannot self-assign
  //     admin or platoon_leader roles through the public registration form.
  //   • status is set to 'approved' — cadets are automatically approved upon
  //     registration and can immediately access the cadet portal with their
  //     Digital ID card and attendance QR code.
  //
  // NOTE: Even though role/status are hardcoded here, the real enforcement
  //   is in Supabase's Row-Level Security policies. The JS values here are
  //   a first layer; the database policies are the authoritative layer.
  // ========================================================================
  async register(formData) {

    // ------------------------------------------------------------------
    // STEP 1 — Create the authentication account (auth.users record)
    // ------------------------------------------------------------------
    // signUp() creates a new entry in Supabase's internal auth.users table.
    // This is what enables password-based login. It does NOT store any
    // application-specific data (name, student ID, etc.) — that's Step 2.
    const { data: authData, error: authError } = await window.supabaseClient.auth.signUp({
      email: formData.email.trim().toLowerCase(), // Normalize email format
      password: formData.password,
      options: {
        data: {
          first_name: formData.first_name,
          last_name: formData.last_name,
          student_id: formData.student_id,
          role: "cadet"
        }
      }
    });

    // If signup failed (e.g., email already registered, weak password, or rate limit),
    // throw the error immediately and skip Step 2.
    if (authError) throw authError;

    // Extract the new user's UUID from the response.
    // Optional chaining (?.) safely handles the case where authData.user
    // might be null (can happen if email confirmation is required and the
    // user already exists but hasn't confirmed yet).
    const userId = authData.user?.id;

    // If we somehow didn't get a user ID back, throw a descriptive error.
    // This prevents us from inserting a profile record with a null user_id
    // which would violate the foreign key constraint in the database.
    if (!userId) throw new Error("Account creation failed. Please verify email settings.");

    // ------------------------------------------------------------------
    // STEP 2 — Insert the profile record (public.profiles row)
    // ------------------------------------------------------------------
    // Insert only columns that exist in the Supabase public.profiles table
    const profilePayload = {
      user_id: userId,                              // Links this profile to the auth user
      first_name: formData.first_name,
      middle_name: formData.middle_name || null,
      last_name: formData.last_name,
      student_id: formData.student_id,
      email: formData.email.trim().toLowerCase(),  // Stored for display
      phone: formData.phone,
      course: formData.course,
      year_level: formData.year_level,
      section: formData.section,
      date_of_birth: formData.date_of_birth,
      address: formData.address,
      company: formData.company || null,
      platoon: formData.platoon || null,

      // !! SECURITY-CRITICAL LINES !!
      role: "cadet",      // Public sign-up is always 'cadet'
      status: "approved", // Auto-approved on registration for immediate access
    };

    // Insert the profile row into the `profiles` table.
    const { data: profileData, error: profError } = await window.supabaseClient
      .from("profiles")
      .insert(profilePayload)
      .select("id")
      .single();

    // If the profile insert failed (e.g., duplicate student_id), throw the error
    if (profError) throw profError;

    // STEP 3 — Auto-create cadets table entry for QR scanner + attendance tracking.
    // Without this row, the QR scanner cannot record attendance for the cadet.
    // Wrapped in try/catch so a cadets-table failure doesn't break the whole signup.
    try {
      if (profileData?.id) {
        await window.supabaseClient
          .from("cadets")
          .insert({
            profile_id: profileData.id,
            rotc_unit:  formData.company || "Alpha Company",
            rank:       "Cadet"
          });
      }
    } catch (cadErr) {
      // Non-fatal: scanner will auto-create the record on first scan if missing
      console.warn("Could not auto-create cadets entry at registration:", cadErr);
    }

    // Return the auth data so the register page can check if email
    // confirmation is required before redirecting the user.
    return authData;
  },

  // ========================================================================
  // METHOD: logout()
  // ========================================================================
  // Signs the current user out of Supabase and redirects them to the login
  // page. signOut() clears the session from localStorage, invalidates the
  // access token on the Supabase server, and clears all cached auth state
  // in the Supabase client instance.
  //
  // Called by: The logout button found in every authenticated page's sidebar.
  // ========================================================================
  async logout() {
    // Tell Supabase to end the server-side session and clear local storage.
    // After this call, getSession() will return null.
    await window.supabaseClient.auth.signOut();

    // Redirect to the login page. Using window.location.href causes a full
    // page navigation, which also clears any in-memory state from the JS
    // runtime — an important security measure to prevent the next user on
    // the same machine from using the browser's Back button to see cached content.
    window.location.href = "login.html";
  },

  // ========================================================================
  // METHOD: requireAuth(allowedRoles)
  // ========================================================================
  // The main ROUTE GUARD function. Every protected page calls this at the
  // top of its page-specific script to enforce access control.
  //
  // Parameter:
  //   allowedRoles {Array<string>} — List of roles that may access the page.
  //     Example: Auth.requireAuth(['admin'])           — admin only
  //              Auth.requireAuth(['admin', 'platoon_leader']) — both roles
  //              Auth.requireAuth([])                  — any logged-in user
  //
  // Returns: The profile object if the user is authorized, or null if not
  //          (and the user will have been redirected away before null returns).
  //
  // FLOW:
  //   1. Check for a valid session → if missing, redirect to login
  //   2. Fetch the user's profile  → if missing, log out
  //   3. Check the user's role     → if unauthorized, redirect to their dashboard
  //   4. Update the page UI        → inject name/role into the top bar
  //   5. Return the profile        → page script can use it to load data
  //
  // HOW TO USE ON A PROTECTED PAGE:
  //   const profile = await Auth.requireAuth(['admin']);
  //   if (!profile) return; // Guard redirected — stop script execution
  //   // ... rest of page initialization using profile data
  // ========================================================================
  async requireAuth(allowedRoles = []) {

    // ---- Step 1: Verify session ----
    const session = await this.getSession();

    if (!session) {
      // No session = user is not logged in.
      // Redirect to login.html and append the current page path as a
      // `redirect` query parameter so that after successful login, the
      // login page can send the user back to where they intended to go.
      // encodeURIComponent() makes the path safe to embed in a URL.
      window.location.href = `login.html?redirect=${encodeURIComponent(window.location.pathname)}`;

      // Return null to signal that authorization failed.
      // The calling page script should check for this and stop execution.
      return null;
    }

    // ---- Step 2: Verify profile exists ----
    const profile = await this.getProfile();

    if (!profile) {
      // A session exists but no profile row was found. This is an unusual
      // state that can happen if: (a) the profile insert in register() failed
      // silently, or (b) an admin manually deleted the profile from the DB.
      // We alert the user with an actionable message and force logout to
      // clear the broken session state.
      alert("No profile found for this account. Please contact ROTC command staff.");
      await this.logout(); // Clears the orphaned session and redirects to login
      return null;
    }

    // ---- Step 3: Verify role authorization ----
    // Only perform the role check if the caller specified a non-empty list.
    // An empty allowedRoles array means "any authenticated user is fine".
    if (allowedRoles.length > 0 && !allowedRoles.includes(profile.role)) {
      // The user IS logged in, but their role is not in the allowed list.
      // For example: a cadet trying to access admin-dashboard.html.
      alert("Unauthorized access. You do not have permission to view this portal.");

      // Redirect the user to THEIR correct dashboard rather than just
      // showing an error page — better UX and prevents confusion.
      if (profile.role === "cadet") {
        window.location.href = "cadet-dashboard.html";   // Cadets → cadet portal
      } else {
        window.location.href = "admin-dashboard.html";   // All other roles → admin portal
      }

      return null; // Stop execution; redirect is in progress
    }

    // ---- Step 4: Render user info in the page UI ----
    // At this point the user is confirmed to be logged in AND authorized.
    // Populate the name, role badge, and avatar initials in the top bar.
    this.updateUI(profile);

    // ---- Step 5: Return the profile ----
    // The calling page script receives the full profile object and can use
    // it to make data queries (e.g., "show only MY attendance records").
    return profile;
  },

  // ========================================================================
  // METHOD: updateUI(profile)
  // ========================================================================
  // Injects the logged-in user's name, role, and avatar initials into
  // standard HTML elements that are expected to exist in every page's
  // top navigation bar. Pages must have elements with these IDs:
  //   #user-name   — displays "FirstName LastName"
  //   #user-role   — displays the role label in uppercase
  //   #user-avatar — displays the user's initials (e.g., "JD" for John Doe)
  //
  // Called by: requireAuth() (automatically after access is granted).
  //            Can also be called manually if a page needs to refresh the UI.
  // ========================================================================
  updateUI(profile) {
    // Safely grab each element — they may not exist on every page layout.
    const nameEl   = document.getElementById("user-name");
    const roleEl   = document.getElementById("user-role");
    const avatarEl = document.getElementById("user-avatar");

    // Set the displayed name: "FirstName LastName"
    // The `if (nameEl)` guard prevents a crash if the element doesn't exist.
    if (nameEl) nameEl.textContent = `${profile.first_name} ${profile.last_name}`;

    if (roleEl) {
      // Convert snake_case role values to a human-readable display label.
      // 'platoon_leader' → 'Platoon Leader'. Other roles (admin, cadet) are
      // already readable so they're passed through unchanged and uppercased.
      const roleDisplay = profile.role === "platoon_leader" ? "Platoon Leader" : profile.role;

      // Display the role in ALL CAPS for a bold, badge-like appearance.
      roleEl.textContent = roleDisplay.toUpperCase();
    }

    if (avatarEl) {
      // Build initials from the first character of first and last name.
      // `|| ""` provides an empty string fallback if either name is missing,
      // preventing "undefined"[0] from returning "u" as an initial.
      const initials = `${profile.first_name[0] || ""}${profile.last_name[0] || ""}`;

      // Display initials in uppercase inside the circular avatar element.
      avatarEl.textContent = initials.toUpperCase();
    }
  },
};

// ==========================================================================
// SECTION 2 — Global Mobile Sidebar Toggle Helper
// ==========================================================================
// This standalone function is intentionally placed OUTSIDE the Auth object
// because it is unrelated to authentication — it is a UI utility.
//
// It is declared as a regular named function (not an arrow function or method)
// so it can be called directly from an HTML onclick attribute:
//   <button onclick="toggleMobileMenu()">☰</button>
//
// WHY HERE AND NOT IN nav.js?
//   Dashboard pages use a SIDEBAR layout (not the top navbar used by public
//   pages). The sidebar's toggle behavior is simpler (one CSS class swap)
//   and is wired up via inline onclick in the HTML, so it lives here in
//   auth.js which is already loaded by every dashboard page.
// ==========================================================================
function toggleMobileMenu() {
  const sidebar = document.querySelector(".sidebar");
  if (!sidebar) return;

  const isOpen = sidebar.classList.toggle("mobile-open");

  // Ensure an overlay backdrop exists for touch dismissal
  let backdrop = document.getElementById("sidebar-backdrop");
  if (!backdrop) {
    backdrop = document.createElement("div");
    backdrop.id = "sidebar-backdrop";
    backdrop.style.cssText = "position:fixed;inset:0;background:rgba(0,0,0,0.55);backdrop-filter:blur(2px);z-index:9998;display:none;transition:opacity 0.25s;";
    backdrop.onclick = () => {
      sidebar.classList.remove("mobile-open");
      backdrop.style.display = "none";
    };
    document.body.appendChild(backdrop);
  }

  if (isOpen) {
    backdrop.style.display = "block";
    // Close sidebar when clicking any menu link
    sidebar.querySelectorAll("a").forEach(link => {
      link.addEventListener("click", () => {
        sidebar.classList.remove("mobile-open");
        backdrop.style.display = "none";
      }, { once: true });
    });
  } else {
    backdrop.style.display = "none";
  }
}

// ==========================================================================
// TACTICAL MOBILE APP EXTENSIONS (Floating Toast & Bottom Navigation)
// ==========================================================================

/**
 * Displays a tactile floating confirmation banner at the bottom of the screen
 * on mobile devices, matching the tactical HUD reference design.
 * @param {string} message - Text notification (e.g., "Cadet Juan marked as APPROVED!")
 * @param {'success'|'error'|'warning'} type - Visual color tone
 */
window.showMobileToast = function(message, type = 'success') {
  let toast = document.getElementById("mobile-floating-toast");
  if (!toast) {
    toast = document.createElement("div");
    toast.id = "mobile-floating-toast";
    document.body.appendChild(toast);
  }

  const icon = type === 'error' ? '✕' : (type === 'warning' ? '⚠️' : '✓');
  toast.innerHTML = `<span style="display:inline-block; margin-right:0.4rem; font-weight:900;">${icon}</span> ${message}`;

  if (type === 'error') {
    toast.style.borderColor = '#ef4444';
    toast.style.color = '#fee2e2';
    toast.style.background = 'linear-gradient(135deg, #450a0a, #7f1d1d)';
  } else if (type === 'warning') {
    toast.style.borderColor = '#eab308';
    toast.style.color = '#fef3c7';
    toast.style.background = 'linear-gradient(135deg, #422006, #713f12)';
  } else {
    toast.style.borderColor = 'var(--brass, #b88e2c)';
    toast.style.color = '#fef08a';
    toast.style.background = 'linear-gradient(135deg, #052e16, #14532d)';
  }

  toast.style.display = "block";
  if (window._toastTimer) clearTimeout(window._toastTimer);
  window._toastTimer = setTimeout(() => {
    toast.style.display = "none";
  }, 3200);
};

/**
 * Automatically injects the unified mobile bottom navigation bar into all
 * portal dashboard pages for tactical handheld terminal comfort.
 * Tabs matching military design mockup: Command | Scanner | Attendance | Cadets | More
 */
function mountMobileBottomNav() {
  if (!document.querySelector(".portal-layout") && !document.querySelector(".sidebar")) return;
  if (document.querySelector(".portal-mobile-bottom-nav")) return;

  const currentFile = (window.location.pathname.split("/").pop() || "index.html").toLowerCase();
  const isCadetPortal = currentFile.startsWith("cadet-");

  const nav = document.createElement("nav");
  nav.className = "portal-mobile-bottom-nav";

  if (isCadetPortal) {
    nav.innerHTML = `
      <a href="cadet-dashboard.html" class="portal-mob-tab ${currentFile === 'cadet-dashboard.html' || currentFile === 'cadet-qr.html' ? 'active' : ''}">
        <i class="fa-solid fa-id-card"></i>
        <span>My ID &amp; QR</span>
      </a>
      <a href="cadet-modules.html" class="portal-mob-tab ${currentFile === 'cadet-modules.html' ? 'active' : ''}">
        <i class="fa-solid fa-book-open"></i>
        <span>Modules</span>
      </a>
      <a href="cadet-profile.html" class="portal-mob-tab ${currentFile === 'cadet-profile.html' ? 'active' : ''}">
        <i class="fa-solid fa-user-gear"></i>
        <span>Profile</span>
      </a>
      <button type="button" class="portal-mob-tab" onclick="toggleMobileMenu()">
        <i class="fa-solid fa-bars"></i>
        <span>Menu</span>
      </button>
    `;
  } else {
    // Admin / Officer 5 Handheld Tabs matching UI Spec
    nav.innerHTML = `
      <a href="admin-dashboard.html" class="portal-mob-tab ${currentFile === 'admin-dashboard.html' ? 'active' : ''}">
        <i class="fa-solid fa-house"></i>
        <span>Command</span>
      </a>
      <a href="admin-qr-scanner.html" class="portal-mob-tab ${currentFile === 'admin-qr-scanner.html' ? 'active' : ''}">
        <i class="fa-solid fa-qrcode"></i>
        <span>Scanner</span>
      </a>
      <a href="admin-attendance.html" class="portal-mob-tab ${currentFile === 'admin-attendance.html' ? 'active' : ''}">
        <i class="fa-solid fa-clipboard-check"></i>
        <span>Attendance</span>
      </a>
      <a href="admin-cadets.html" class="portal-mob-tab ${currentFile === 'admin-cadets.html' ? 'active' : ''}">
        <i class="fa-solid fa-users"></i>
        <span>Cadets</span>
      </a>
      <button type="button" class="portal-mob-tab" onclick="toggleMoreMenu()">
        <i class="fa-solid fa-bars"></i>
        <span>More</span>
      </button>
    `;
  }

  document.body.appendChild(nav);
}

/**
 * Dedicated More Menu Sheet (Matching Screen 7 in design mockups)
 */
window.toggleMoreMenu = function() {
  let modal = document.getElementById("mobile-more-menu-sheet");
  if (!modal) {
    modal = document.createElement("div");
    modal.id = "mobile-more-menu-sheet";
    modal.className = "mobile-more-sheet-overlay";
    document.body.appendChild(modal);
  }

  const profile = Auth.currentProfile || {};
  const fullName = `${profile.first_name || ''} ${profile.last_name || ''}`.trim() || "Administrator";
  const roleName = profile.role === 'admin' ? 'System Administrator' : (profile.role ? profile.role.toUpperCase() : 'Officer');
  const avatarInitials = ((profile.first_name?.[0] || 'A') + (profile.last_name?.[0] || 'D')).toUpperCase();

  modal.innerHTML = `
    <div class="mobile-more-sheet-content">
      <div class="mobile-more-header">
        <h2>More</h2>
        <a href="admin-settings.html" class="btn-more-gear" title="Settings"><i class="fa-solid fa-gear"></i></a>
      </div>

      <!-- Identity Card -->
      <div class="mobile-more-profile-card">
        <div class="more-avatar">${avatarInitials}</div>
        <div class="more-user-info">
          <div class="more-user-name">${fullName}</div>
          <div class="more-user-role">${roleName}</div>
        </div>
        <i class="fa-solid fa-chevron-right more-chevron"></i>
      </div>

      <!-- Navigation Links -->
      <div class="mobile-more-list-card">
        <a href="admin-applications.html" class="mobile-more-item">
          <div class="item-icon-box"><i class="fa-solid fa-user-check"></i></div>
          <span class="item-title">Enlistment</span>
          <i class="fa-solid fa-chevron-right"></i>
        </a>
        <a href="admin-attendance.html" class="mobile-more-item">
          <div class="item-icon-box"><i class="fa-solid fa-calendar-check"></i></div>
          <span class="item-title">Formation Sessions</span>
          <i class="fa-solid fa-chevron-right"></i>
        </a>
        <a href="admin-posting.html" class="mobile-more-item">
          <div class="item-icon-box"><i class="fa-solid fa-bullhorn"></i></div>
          <span class="item-title">Announcements</span>
          <i class="fa-solid fa-chevron-right"></i>
        </a>
        <a href="admin-documents.html" class="mobile-more-item">
          <div class="item-icon-box"><i class="fa-solid fa-graduation-cap"></i></div>
          <span class="item-title">Training</span>
          <i class="fa-solid fa-chevron-right"></i>
        </a>
        <a href="admin-reports.html" class="mobile-more-item">
          <div class="item-icon-box"><i class="fa-solid fa-chart-column"></i></div>
          <span class="item-title">Reports</span>
          <i class="fa-solid fa-chevron-right"></i>
        </a>
        <a href="admin-accounts.html" class="mobile-more-item">
          <div class="item-icon-box"><i class="fa-solid fa-users-gear"></i></div>
          <span class="item-title">User Management</span>
          <i class="fa-solid fa-chevron-right"></i>
        </a>
        <a href="admin-settings.html" class="mobile-more-item">
          <div class="item-icon-box"><i class="fa-solid fa-gear"></i></div>
          <span class="item-title">Settings</span>
          <i class="fa-solid fa-chevron-right"></i>
        </a>
      </div>

      <!-- Logout Button -->
      <button type="button" class="btn-more-logout" onclick="Auth.logout()">
        <i class="fa-solid fa-arrow-right-from-bracket"></i> Log Out
      </button>

      <!-- Close Sheet Button -->
      <button type="button" class="btn-more-close" onclick="closeMoreMenu()">
        ✕ Close
      </button>
    </div>
  `;

  modal.classList.add("active");
  document.body.style.overflow = "hidden";
};

window.closeMoreMenu = function() {
  const modal = document.getElementById("mobile-more-menu-sheet");
  if (modal) modal.classList.remove("active");
  document.body.style.overflow = "";
};

// Mount bottom navigation when document is loaded
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", mountMobileBottomNav);
} else {
  mountMobileBottomNav();
}
