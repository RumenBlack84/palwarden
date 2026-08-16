// SPDX-License-Identifier: AGPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Brian Grant
//
// Shared behavior for the palwarden pages: sidebar collapse/expand and the
// theme toggle. The sidebar markup itself is static in every page so
// navigation works without JS; this only adds the conveniences.
//
// Storage keys are shared across pages on purpose: 'theme' is the same key the
// settings editor has always used (so its own header toggle and this one agree),
// and 'palwarden-sidebar' keeps the collapsed state consistent as the operator
// moves between tabs.
(function () {
  'use strict';
  var SIDEBAR_KEY = 'palwarden-sidebar';
  var THEME_KEY = 'theme';

  function applyCollapsed(collapsed) {
    document.body.classList.toggle('pw-sidebar-collapsed', collapsed);
    var toggle = document.getElementById('pw-sidebar-toggle');
    if (toggle) {
      toggle.setAttribute('aria-expanded', String(!collapsed));
      toggle.title = collapsed ? 'Expand sidebar' : 'Collapse sidebar';
    }
  }

  function applyTheme(theme) {
    document.body.setAttribute('data-theme', theme);
    var icon = document.querySelector('#pw-theme-toggle .pw-sidebar__emoji');
    if (icon) icon.textContent = theme === 'dark' ? '☀️' : '🌙';
    // The settings editor's own header toggle keeps its icon in sync itself;
    // both read and write the same localStorage key.
    var headerIcon = document.querySelector('.theme-icon');
    if (headerIcon) headerIcon.textContent = theme === 'dark' ? '☀️' : '🌙';
  }

  document.addEventListener('DOMContentLoaded', function () {
    applyCollapsed(localStorage.getItem(SIDEBAR_KEY) === 'collapsed');
    applyTheme(localStorage.getItem(THEME_KEY) || 'dark');

    var toggle = document.getElementById('pw-sidebar-toggle');
    if (toggle) {
      toggle.addEventListener('click', function () {
        var collapsed = !document.body.classList.contains('pw-sidebar-collapsed');
        localStorage.setItem(SIDEBAR_KEY, collapsed ? 'collapsed' : 'expanded');
        applyCollapsed(collapsed);
      });
    }
    var themeBtn = document.getElementById('pw-theme-toggle');
    if (themeBtn) {
      themeBtn.addEventListener('click', function () {
        var next = document.body.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
        localStorage.setItem(THEME_KEY, next);
        applyTheme(next);
      });
    }
  });
})();
