// ==========================================================================
// FILE: nav.js
// PURPOSE: Handles the responsive mobile hamburger navigation menu for all
//          public-facing pages of ROTCIMS (e.g., landing page, about, login).
//
// USED BY: Every public HTML page that has a top navigation bar.
//          Include this script at the BOTTOM of <body> (just before </body>)
//          so the DOM elements it references are guaranteed to exist when
//          this code runs. Loading it in <head> without "defer" would cause
//          document.getElementById to return null because the HTML hasn't
//          been parsed yet.
//
// HOW IT WORKS:
//   On narrow screens (mobile/tablet), the full nav link list is hidden.
//   A "hamburger" button (☰) becomes visible instead. Clicking it toggles
//   a CSS class ('nav-open') on the <nav> element, which the stylesheet
//   uses to slide or fade the menu into view. The button icon also swaps
//   between ☰ (closed) and ✕ (open) to give the user clear feedback.
//   Three close triggers are registered:
//     1. Clicking a nav link  → closes the menu (useful for anchor links)
//     2. Clicking outside     → closes the menu (standard UX expectation)
//     3. Clicking the button  → toggles the menu (open ↔ close)
//
// ACCESSIBILITY NOTE:
//   The toggle button's aria-expanded attribute is kept in sync with the
//   menu state. Screen readers use this attribute to announce to visually
//   impaired users whether the navigation menu is currently open or closed.
// ==========================================================================

// --------------------------------------------------------------------------
// SECTION 1 — IIFE Wrapper (Immediately Invoked Function Expression)
// --------------------------------------------------------------------------

// Wrapping the entire script in an IIFE creates a private scope.
// Any variables declared inside (toggle, nav) do NOT pollute the global
// window object, preventing accidental name collisions with other scripts.
(function () {

  // --------------------------------------------------------------------------
  // SECTION 2 — Element References
  // --------------------------------------------------------------------------

  // Grab the hamburger button by its ID.
  // This is the ☰ / ✕ button that the user clicks to open/close the menu.
  const toggle = document.getElementById('nav-toggle');

  // Grab the <nav> container that wraps all navigation links.
  // The CSS class 'nav-open' is toggled on this element to show/hide links.
  const nav    = document.getElementById('site-nav');

  // --------------------------------------------------------------------------
  // SECTION 3 — Early Exit Guard
  // --------------------------------------------------------------------------

  // If either element is missing (e.g., on a page that doesn't have a nav bar),
  // stop the script immediately. Without this guard, attaching event listeners
  // to null would throw a TypeError and crash other scripts on the page.
  if (!toggle || !nav) return;

  // --------------------------------------------------------------------------
  // SECTION 4 — Hamburger Button Click Handler (Open / Close Toggle)
  // --------------------------------------------------------------------------

  toggle.addEventListener('click', function () {

    // classList.toggle() adds the class if absent, removes it if present,
    // and RETURNS true if the class is now present (menu is now open).
    // We capture that boolean in `isOpen` to drive the two UI updates below.
    const isOpen = nav.classList.toggle('nav-open');

    // Keep the aria-expanded attribute in sync with the actual menu state.
    // Assistive technologies (screen readers) read this attribute to tell
    // the user whether the menu is currently open or closed.
    toggle.setAttribute('aria-expanded', isOpen ? 'true' : 'false');

    // Swap the button icon to reflect the current state:
    //   \u2715 = ✕ (close / X symbol) — shown while the menu is OPEN
    //   \u2261 = ☰ (hamburger / three-bar symbol) — shown while menu is CLOSED
    // Unicode escapes are used here to avoid any character-encoding issues
    // if this file is opened in an editor with a different default encoding.
    toggle.textContent = isOpen ? '\u2715' : '\u2261';
  });

  // --------------------------------------------------------------------------
  // SECTION 5 — Close Menu on Nav Link Click
  // --------------------------------------------------------------------------

  // Listen for clicks on the entire <nav> element.
  // Event delegation: instead of attaching a listener to every <a> tag
  // individually, we listen on the parent and check what was clicked.
  // This is more efficient and works even if links are added dynamically.
  nav.addEventListener('click', function (e) {

    // Only act if the clicked element is an anchor (<a>) tag.
    // e.target is the specific element the user actually clicked on.
    if (e.target.tagName === 'A') {

      // Remove the 'nav-open' class to visually close the menu.
      nav.classList.remove('nav-open');

      // Reset aria-expanded to 'false' so screen readers know it's closed.
      toggle.setAttribute('aria-expanded', 'false');

      // Reset the icon back to ☰ (hamburger) since the menu is now closed.
      toggle.textContent = '\u2261';
    }
  });

  // --------------------------------------------------------------------------
  // SECTION 6 — Close Menu on Outside Click
  // --------------------------------------------------------------------------

  // Listen for ANY click anywhere on the document.
  // This implements the standard UX pattern where clicking outside a menu
  // dismisses it — matching how native dropdowns and modals behave.
  document.addEventListener('click', function (e) {

    // Node.contains() checks whether a given element is inside another.
    // We only close the menu if the click was OUTSIDE both the toggle
    // button AND the nav panel. If the user clicked either of those, the
    // click-on-toggle handler above already handled it correctly.
    if (!toggle.contains(e.target) && !nav.contains(e.target)) {

      // Close the menu by removing the open class.
      nav.classList.remove('nav-open');

      // Sync aria-expanded for accessibility.
      toggle.setAttribute('aria-expanded', 'false');

      // Reset the icon to the hamburger symbol.
      toggle.textContent = '\u2261';
    }
  });

// End of IIFE — the parentheses at the end immediately invoke this function.
})();
