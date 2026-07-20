/* Lumen — Theme Toggle
   Stores preference in a cookie and applies the data-theme attribute to <html> */

(function () {
  'use strict';

  function getCookie(name) {
    var match = document.cookie.match(new RegExp('(^| )' + name + '=([^;]+)'));
    return match ? match[2] : null;
  }

  function setCookie(name, value, days) {
    var expires = '';
    if (days) {
      var d = new Date();
      d.setTime(d.getTime() + days * 86400000);
      expires = '; expires=' + d.toUTCString();
    }
    document.cookie = name + '=' + value + expires + '; path=/; SameSite=Lax';
  }

  function applyTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
  }

  // Initialize theme from cookie, default to light
  var savedTheme = getCookie('theme');
  if (savedTheme === 'dark' || savedTheme === 'light') {
    applyTheme(savedTheme);
  }

  // Toggle button
  var toggle = document.getElementById('themeToggle');
  if (toggle) {
    toggle.addEventListener('click', function () {
      var current = document.documentElement.getAttribute('data-theme');
      var next = current === 'dark' ? 'light' : 'dark';
      applyTheme(next);
      setCookie('theme', next, 365);
    });
  }
})();
