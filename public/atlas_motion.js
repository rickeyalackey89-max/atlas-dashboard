(function () {
  "use strict";

  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduceMotion) {
    document.documentElement.classList.remove("atlas-handoff-pending");
    return;
  }

  var overlay;
  var canvas;
  var ctx;
  var nodes = [];
  var active = false;
  var duration = 1180;
  var arrivalDuration = 1080;
  var arrivalHold = 230;
  var departureHold = 180;
  var storageKey = "atlas_transition_handoff";

  function updateChromeShift() {
    var y = window.scrollY || document.documentElement.scrollTop || 0;
    var shift = ((y % 260) - 130) * 0.32;
    document.documentElement.style.setProperty("--atlas-scroll-shine", shift.toFixed(1) + "px");
  }

  function createOverlay(handoff) {
    if (overlay) return;

    overlay = document.createElement("div");
    overlay.className = "atlas-neural-transition";
    overlay.setAttribute("aria-hidden", "true");
    overlay.innerHTML = '<canvas></canvas><div class="atlas-transition-core"></div><div class="atlas-transition-label">Model Sync</div>';
    document.body.appendChild(overlay);

    canvas = overlay.querySelector("canvas");
    ctx = canvas.getContext("2d");
    resizeCanvas(handoff);
    window.addEventListener("resize", resizeCanvas, { passive: true });
  }

  function setLabel(text) {
    if (!overlay) return;
    var label = overlay.querySelector(".atlas-transition-label");
    if (label) label.textContent = text || "Model Sync";
  }

  function resizeCanvas(handoff) {
    if (!canvas) return;
    var dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
    var width = window.innerWidth;
    var height = window.innerHeight;
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (handoff && handoff.nodes && handoff.width && handoff.height) {
      restoreNodes(handoff, width, height);
    } else {
      seedNodes(width, height);
    }
  }

  function seedNodes(width, height) {
    nodes = [];
    var count = Math.max(34, Math.min(62, Math.floor(width / 24)));
    for (var i = 0; i < count; i += 1) {
      nodes.push({
        x: Math.random() * width,
        y: Math.random() * height,
        vx: (Math.random() - 0.5) * 0.55,
        vy: (Math.random() - 0.5) * 0.55,
        r: 1.2 + Math.random() * 2.4
      });
    }
  }

  function restoreNodes(handoff, width, height) {
    var sx = width / Math.max(1, handoff.width || width);
    var sy = height / Math.max(1, handoff.height || height);
    nodes = handoff.nodes.slice(0, 70).map(function (node) {
      return {
        x: Number(node.x || 0) * sx,
        y: Number(node.y || 0) * sy,
        vx: Number(node.vx || 0),
        vy: Number(node.vy || 0),
        r: Number(node.r || 2)
      };
    });
    if (!nodes.length) seedNodes(width, height);
  }

  function snapshotNodes() {
    return {
      width: window.innerWidth,
      height: window.innerHeight,
      nodes: nodes.map(function (node) {
        return {
          x: Math.round(node.x * 10) / 10,
          y: Math.round(node.y * 10) / 10,
          vx: Math.round(node.vx * 1000) / 1000,
          vy: Math.round(node.vy * 1000) / 1000,
          r: Math.round(node.r * 10) / 10
        };
      })
    };
  }

  function easeInOut(t) {
    return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2;
  }

  function writeHandoff(destination, extra) {
    try {
      var payload = {
        from: window.location.pathname,
        to: destination.pathname,
        ts: Date.now()
      };
      if (extra) {
        payload.width = extra.width;
        payload.height = extra.height;
        payload.nodes = extra.nodes;
      }
      sessionStorage.setItem(storageKey, JSON.stringify(payload));
    } catch (err) {}
  }

  function draw(progress) {
    var width = window.innerWidth;
    var height = window.innerHeight;
    ctx.clearRect(0, 0, width, height);

    var pulse = Math.sin(progress * Math.PI);
    var cx = width * 0.5;
    var cy = height * 0.5;
    var linkDistance = 155 + pulse * 95;

    for (var i = 0; i < nodes.length; i += 1) {
      var a = nodes[i];
      a.x += a.vx * (1 + pulse);
      a.y += a.vy * (1 + pulse);

      if (a.x < -20) a.x = width + 20;
      if (a.x > width + 20) a.x = -20;
      if (a.y < -20) a.y = height + 20;
      if (a.y > height + 20) a.y = -20;

      for (var j = i + 1; j < nodes.length; j += 1) {
        var b = nodes[j];
        var dx = a.x - b.x;
        var dy = a.y - b.y;
        var dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < linkDistance) {
          var alpha = (1 - dist / linkDistance) * (0.08 + pulse * 0.3);
          ctx.strokeStyle = "rgba(0,216,255," + alpha.toFixed(3) + ")";
          ctx.lineWidth = 1;
          ctx.beginPath();
          ctx.moveTo(a.x, a.y);
          ctx.lineTo(b.x, b.y);
          ctx.stroke();
        }
      }

      var coreDx = a.x - cx;
      var coreDy = a.y - cy;
      var coreDist = Math.sqrt(coreDx * coreDx + coreDy * coreDy);
      if (coreDist < 310) {
        ctx.strokeStyle = "rgba(238,246,249," + ((1 - coreDist / 310) * pulse * 0.22).toFixed(3) + ")";
        ctx.beginPath();
        ctx.moveTo(a.x, a.y);
        ctx.lineTo(cx, cy);
        ctx.stroke();
      }

      ctx.fillStyle = "rgba(238,246,249," + (0.4 + pulse * 0.45).toFixed(3) + ")";
      ctx.beginPath();
      ctx.arc(a.x, a.y, a.r + pulse * 1.2, 0, Math.PI * 2);
      ctx.fill();
    }
  }

  function labelForPath(pathname, fallback) {
    if (pathname.indexOf("/dashboard") === 0) return "Entering Model";
    if (pathname.indexOf("/checkout") === 0) return "Secure Checkout";
    if (pathname.indexOf("/ambassadors") === 0) return "Ambassador Hub";
    if (pathname.indexOf("/join") === 0) return "Atlas Network";
    return fallback || "Model Sync";
  }

  function startTransition(url) {
    if (active) return;
    active = true;
    createOverlay();
    var destination = new URL(url, window.location.href);
    setLabel(labelForPath(destination.pathname, "Model Sync"));
    writeHandoff(destination);
    document.body.classList.add("atlas-transition-out");
    overlay.classList.add("is-active");

    var start = performance.now();
    function frame(now) {
      var rawProgress = Math.min(1, (now - start) / duration);
      var progress = easeInOut(rawProgress);
      draw(progress);
      if (rawProgress < 1) {
        requestAnimationFrame(frame);
      } else {
        writeHandoff(destination, snapshotNodes());
        window.setTimeout(function () {
          window.location.href = url;
        }, departureHold);
      }
    }
    requestAnimationFrame(frame);
  }

  function playArrivalIfPending() {
    var payload = null;
    try {
      var raw = sessionStorage.getItem(storageKey);
      if (raw) payload = JSON.parse(raw);
      sessionStorage.removeItem(storageKey);
    } catch (err) {
      payload = null;
    }
    if (!payload || !payload.ts || Date.now() - payload.ts > 5000) {
      document.documentElement.classList.remove("atlas-handoff-pending");
      return;
    }

    active = true;
    createOverlay(payload);
    setLabel(labelForPath(window.location.pathname, "Model Ready"));
    document.body.classList.add("atlas-transition-entering");
    overlay.classList.add("is-active", "is-arriving");
    draw(1);

    window.setTimeout(function () {
      document.documentElement.classList.remove("atlas-handoff-pending");
      document.body.classList.remove("atlas-transition-entering");
      document.body.classList.add("atlas-transition-in");
      overlay.classList.remove("is-active");
    }, arrivalHold);

    window.setTimeout(function () {
      document.body.classList.remove("atlas-transition-in");
      overlay.classList.remove("is-arriving");
      active = false;
      draw(0);
    }, arrivalDuration + arrivalHold);
  }

  function shouldHandle(event, link) {
    if (!link || event.defaultPrevented) return false;
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return false;
    if (link.target && link.target !== "_self") return false;
    if (link.hasAttribute("download") || link.dataset.noTransition === "true") return false;

    var href = link.getAttribute("href");
    if (!href || href.charAt(0) === "#" || href.indexOf("mailto:") === 0 || href.indexOf("tel:") === 0) return false;

    var url;
    try {
      url = new URL(href, window.location.href);
    } catch (err) {
      return false;
    }

    if (url.origin !== window.location.origin) return false;
    if (url.pathname === window.location.pathname && url.search === window.location.search) return false;
    if (url.pathname.indexOf("/api/") === 0) return false;
    return true;
  }

  document.addEventListener("click", function (event) {
    var link = event.target.closest && event.target.closest("a[href]");
    if (!shouldHandle(event, link)) return;
    event.preventDefault();
    startTransition(link.href);
  });

  window.addEventListener("scroll", updateChromeShift, { passive: true });
  updateChromeShift();

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", playArrivalIfPending, { once: true });
  } else {
    playArrivalIfPending();
  }
})();
