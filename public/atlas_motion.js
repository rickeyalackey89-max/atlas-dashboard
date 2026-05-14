(function () {
  "use strict";

  var reduceMotion = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduceMotion) return;

  var overlay;
  var canvas;
  var ctx;
  var nodes = [];
  var active = false;
  var duration = 720;

  function createOverlay() {
    if (overlay) return;

    overlay = document.createElement("div");
    overlay.className = "atlas-neural-transition";
    overlay.setAttribute("aria-hidden", "true");
    overlay.innerHTML = '<canvas></canvas><div class="atlas-transition-core"></div><div class="atlas-transition-label">Model Sync</div>';
    document.body.appendChild(overlay);

    canvas = overlay.querySelector("canvas");
    ctx = canvas.getContext("2d");
    resizeCanvas();
    window.addEventListener("resize", resizeCanvas, { passive: true });
  }

  function resizeCanvas() {
    if (!canvas) return;
    var dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
    var width = window.innerWidth;
    var height = window.innerHeight;
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
    canvas.style.width = width + "px";
    canvas.style.height = height + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    seedNodes(width, height);
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

  function startTransition(url) {
    if (active) return;
    active = true;
    createOverlay();
    overlay.classList.add("is-active");

    var start = performance.now();
    function frame(now) {
      var progress = Math.min(1, (now - start) / duration);
      draw(progress);
      if (progress < 1) {
        requestAnimationFrame(frame);
      } else {
        window.location.href = url;
      }
    }
    requestAnimationFrame(frame);
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
})();
