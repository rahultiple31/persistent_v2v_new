// Panel settings popup toggle, customer-information scroll arrows and the user profile tray.
// Pure UI. Moved out of index.html unchanged, so the Content Security Policy can forbid inline scripts.
document.addEventListener('DOMContentLoaded', function () {
  // Toggle each panel settings popup on gear-btn click
  document.querySelectorAll('.panel-settings-btn').forEach(function (btn) {
    btn.addEventListener('click', function (e) {
      e.stopPropagation();
      var popupId = btn.getAttribute('data-popup');
      var popup = document.getElementById(popupId);
      if (!popup) return;
      // Close all other open popups first
      document.querySelectorAll('.panel-settings-popup.popup-open').forEach(function (p) {
        if (p !== popup) p.classList.remove('popup-open');
      });
      popup.classList.toggle('popup-open');
    });
  });
  // Close popup on outside click
  document.addEventListener('click', function () {
    document.querySelectorAll('.panel-settings-popup.popup-open').forEach(function (p) {
      p.classList.remove('popup-open');
    });
  });
  // Prevent clicks inside popup from closing it
  document.querySelectorAll('.panel-settings-popup').forEach(function (p) {
    p.addEventListener('click', function (e) { e.stopPropagation(); });
  });

  // ── Customer Information horizontal scroll arrows ──────────────────
  (function () {
    var body = document.getElementById('customerInfoBody');
    var btnL = document.getElementById('ciScrollLeft');
    var btnR = document.getElementById('ciScrollRight');
    if (!body || !btnL || !btnR) return;

    var STEP = 160; // px scrolled per click

    // Update arrow opacity based on current scroll position
    function updateArrows() {
      var atStart = body.scrollLeft <= 0;
      var atEnd = body.scrollLeft >= body.scrollWidth - body.clientWidth - 1;

      // Left arrow: faded when at start, active when scrolled right
      btnL.classList.toggle('ci-arrow-faded', atStart);
      btnL.classList.toggle('ci-arrow-active', !atStart);

      // Right arrow: faded when at end, active when there is more to scroll
      btnR.classList.toggle('ci-arrow-faded', atEnd);
      btnR.classList.toggle('ci-arrow-active', !atEnd);
    }

    // Smooth scroll on click
    btnL.addEventListener('click', function () {
      body.scrollBy({ left: -STEP, behavior: 'smooth' });
    });
    btnR.addEventListener('click', function () {
      body.scrollBy({ left: STEP, behavior: 'smooth' });
    });

    // Re-evaluate arrows on every scroll event
    body.addEventListener('scroll', updateArrows);

    // Initial state on page load
    updateArrows();
  })();
  // ─────────────────────────────────────────────────────────────────────

  // User profile icon — toggle logout tray
  var userProfileBtn = document.getElementById('userProfileButton');
  var userProfileDropdown = document.getElementById('userProfileDropdown');
  if (userProfileBtn && userProfileDropdown) {
    userProfileBtn.addEventListener('click', function (e) {
      e.stopPropagation();
      userProfileDropdown.classList.toggle('hidden');
    });
    // Close tray on outside click
    document.addEventListener('click', function () {
      userProfileDropdown.classList.add('hidden');
    });
    // Prevent clicks inside tray from closing it
    userProfileDropdown.addEventListener('click', function (e) {
      e.stopPropagation();
    });
  }
});
