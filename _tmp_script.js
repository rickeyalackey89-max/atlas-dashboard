var TIER_ORDER = ['GOBLIN','STANDARD','DEMON'];
    var TIER_STYLE = {
      GOBLIN:   { cls: 'goblin',   label: '\u2193 Alts' },
      STANDARD: { cls: 'standard', label: 'Standard' },
      DEMON:    { cls: 'demon',    label: '\u2191 Alts' }
    };
    function loadProps() {
      // Check premium token
      var isPremium = false;
      try {
        var tok = localStorage.getItem('atlas_premium_token');
        if (tok) {
          var td = JSON.parse(atob(tok));
          isPremium = td && td.expires && Date.now() < td.expires;
        }
      } catch(e) {}
      // If logged in, point Dashboard button to /dashboard/ (already is, just update text)
      if (isPremium) {
        var db = document.getElementById('navDashBtn');
        if (db) db.textContent = 'Dashboard →';
      }

      var _fetchCtrl = typeof AbortController !== 'undefined' ? new AbortController() : null;
      var _fetchTimeout = setTimeout(function() { if (_fetchCtrl) _fetchCtrl.abort(); showNoData(); }, 8000);
      fetch('/data/picks_today.json?t=' + Date.now(), _fetchCtrl ? { signal: _fetchCtrl.signal } : {})
        .then(function(r) { clearTimeout(_fetchTimeout); return r.ok ? r.json() : Promise.reject('http ' + r.status); })
        .then(function(data) {
          if (!data) { showNoData(); return; }
          var allLegs = data.picks || [];
          var totalSlips = data.total_slips || 0;
          if (totalSlips > 0) { var sc = document.getElementById('heroSlipCount'); if(sc) sc.textContent = totalSlips; }
          if (data.total_legs > 0) {
            var pb = document.getElementById('heroPickBadge');
            if(pb) { pb.textContent = data.total_legs + ' prop picks today'; pb.style.display = 'inline'; }
          }
          if (!allLegs.length) { showNoData(); return; }
          var grid = document.getElementById('propsGrid');
          grid.innerHTML = '';
          // Show top legs sorted by p_cal desc (already sorted by payload builder)
          var showLegs = allLegs.slice(0, 30);
          for (var i = 0; i < showLegs.length; i++) {
            var leg = showLegs[i];
            var t = (leg.tier||'').toUpperCase();
            var ts = TIER_STYLE[t] || { cls: 'standard', label: '' };
            var dir = (leg.dir||'').toLowerCase();
            var card = document.createElement('div');
            card.className = 'prop-card';
            // Probability: blurred from row 4 onwards for non-premium
            var probHtml = '';
            if (leg.p_cal != null) {
              var pct = Math.round(leg.p_cal * 100);
              var locked = (!isPremium && i >= 3);
              probHtml = '<div class="prob-lock-wrap">' +
                '<div class="prob-pill' + (locked ? ' prob-locked' : '') + '">' + pct + '%</div>' +
                (locked ? '<a href="/checkout/" style="color:var(--gold);font-size:9px;font-weight:800;letter-spacing:.1em;text-transform:uppercase;text-decoration:none;white-space:nowrap;">&#128274; Unlock</a>' : '') +
                '</div>';
            }
            var matchup = (leg.team && leg.opp) ? esc(leg.team) + ' vs ' + esc(leg.opp) : (leg.team ? esc(leg.team) : '');
            card.innerHTML =
              '<div class="prop-card-left">' +
              '<div class="prop-player">' + esc(leg.player||'—') + (ts.label ? ' <span class="tier-badge tier-' + ts.cls + '" style="font-size:8px;padding:2px 6px;vertical-align:middle;">' + esc(ts.label) + '</span>' : '') + '</div>' +
              (matchup ? '<div class="prop-matchup">' + matchup + '</div>' : '') +
              '</div>' +
              '<div class="prop-card-right">' +
              '<span class="prop-stat">' + esc(leg.stat||'') + '</span>' +
              '<span class="prop-line">' + esc(String(leg.line||'—')) + '</span>' +
              '<span class="prop-dir dir-' + dir + '">' + esc((leg.dir||'').toUpperCase()) + '</span>' +
              probHtml +
              '</div>';
            grid.appendChild(card);
          }
          // CTA row if more legs exist
          if (data.total_legs > 30) {
            var cta = document.createElement('div');
            cta.style.cssText = 'padding:14px 20px;text-align:center;font-size:11px;color:var(--t2);border-top:1px solid var(--b);';
            cta.innerHTML = 'Showing top 30 of ' + data.total_legs + ' picks &mdash; <a href="/dashboard/" style="color:var(--gold);font-weight:800;text-decoration:none;">See all in Dashboard &rarr;</a>';
            grid.appendChild(cta);
          }
        }).catch(showNoData);
    }
    function showNoData() {
      document.getElementById('propsGrid').innerHTML = '<div class="no-data-msg">Picks post at 11 AM, 2:30 PM, and 5:30 PM ET on game days.</div>';
    }
    function esc(s) { return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
    loadProps();
