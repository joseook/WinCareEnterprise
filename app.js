// WinCare site: install tabs, copy buttons, reveal on scroll, active TOC. No dependencies, no tracking.
(function () {
  'use strict';
  var root = document.documentElement;
  root.classList.add('js');
  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  function ready(fn) { if (document.readyState !== 'loading') { fn(); } else { document.addEventListener('DOMContentLoaded', fn); } }

  ready(function () {
    // Tabs (arrow keys supported).
    document.querySelectorAll('[data-tabs]').forEach(function (box) {
      var tabs = Array.prototype.slice.call(box.querySelectorAll('[role="tab"]'));
      function select(tab) {
        tabs.forEach(function (t) {
          var on = t === tab;
          t.setAttribute('aria-selected', on ? 'true' : 'false');
          t.tabIndex = on ? 0 : -1;
          document.getElementById(t.getAttribute('aria-controls')).hidden = !on;
        });
      }
      tabs.forEach(function (t, i) {
        t.addEventListener('click', function () { select(t); });
        t.addEventListener('keydown', function (e) {
          if (e.key !== 'ArrowRight' && e.key !== 'ArrowLeft') { return; }
          var n = tabs[(i + (e.key === 'ArrowRight' ? 1 : tabs.length - 1)) % tabs.length];
          select(n); n.focus(); e.preventDefault();
        });
      });
    });

    // Copy buttons.
    var toast = document.querySelector('.toast');
    var toastTimer;
    function notify(msg) {
      if (!toast) { return; }
      toast.textContent = msg; toast.setAttribute('data-show', '');
      clearTimeout(toastTimer); toastTimer = setTimeout(function () { toast.removeAttribute('data-show'); }, 1800);
    }
    function fallbackCopy(text) {
      var ta = document.createElement('textarea');
      ta.value = text; ta.setAttribute('readonly', ''); ta.style.position = 'fixed'; ta.style.opacity = '0';
      document.body.appendChild(ta); ta.select();
      var ok = false; try { ok = document.execCommand('copy'); } catch (e) { ok = false; }
      document.body.removeChild(ta); return ok;
    }
    document.querySelectorAll('.copy[data-copy]').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var el = document.getElementById(btn.getAttribute('data-copy'));
        if (!el) { return; }
        var text = el.textContent.trim();
        var done = function (ok) {
          if (!ok) { notify('Não foi possível copiar. Selecione o texto e copie.'); return; }
          var label = btn.textContent;
          btn.textContent = 'Copiado'; btn.setAttribute('data-done', '');
          notify('Comando copiado. Cole no PowerShell.');
          setTimeout(function () { btn.textContent = label; btn.removeAttribute('data-done'); }, 1600);
        };
        if (navigator.clipboard && window.isSecureContext) {
          navigator.clipboard.writeText(text).then(function () { done(true); }, function () { done(fallbackCopy(text)); });
        } else { done(fallbackCopy(text)); }
      });
    });

    // Reveal on scroll (stagger inside the same parent).
    var items = Array.prototype.slice.call(document.querySelectorAll('.reveal'));
    if (reduce || !('IntersectionObserver' in window)) {
      items.forEach(function (el) { el.classList.add('in'); });
    } else {
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (!en.isIntersecting) { return; }
          var el = en.target;
          var sib = Array.prototype.indexOf.call(el.parentNode.children, el);
          el.style.transitionDelay = Math.min(sib, 6) * 60 + 'ms';
          el.classList.add('in'); io.unobserve(el);
        });
      }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });
      items.forEach(function (el) { io.observe(el); });
    }

    // Active entry in the docs table of contents.
    var links = Array.prototype.slice.call(document.querySelectorAll('.toc a'));
    if ('IntersectionObserver' in window && links.length) {
      var map = {};
      links.forEach(function (a) { map[a.getAttribute('href').slice(1)] = a; });
      var spy = new IntersectionObserver(function (entries) {
        entries.forEach(function (en) {
          if (!en.isIntersecting) { return; }
          links.forEach(function (a) { a.removeAttribute('aria-current'); });
          var a = map[en.target.id]; if (a) { a.setAttribute('aria-current', 'true'); }
        });
      }, { rootMargin: '-20% 0px -70% 0px' });
      Object.keys(map).forEach(function (id) { var h = document.getElementById(id); if (h) { spy.observe(h); } });
    }
  });
})();
