async function loadNetworks() {
  const msg = document.getElementById('msg');
  msg.textContent = 'Scanning...';
  try {
    const res = await fetch('/api/scan');
    const data = await res.json();
    const select = document.getElementById('ssid');
    select.innerHTML = '';
    (data.networks || []).forEach(n => {
      const opt = document.createElement('option');
      opt.value = n.ssid;
      opt.textContent = `${n.ssid} ${n.signal ? '('+n.signal+')' : ''}`;
      select.appendChild(opt);
    });
    msg.textContent = data.networks && data.networks.length ? '' : 'No networks found. Try refresh.';
  } catch (e) {
    msg.textContent = 'Scan failed.';
  }
}

document.getElementById('refresh').addEventListener('click', loadNetworks);

document.getElementById('connect').addEventListener('click', async () => {
  const ssid = document.getElementById('ssid').value;
  const password = document.getElementById('password').value;
  const country = document.getElementById('country').value || 'AT';
  const msg = document.getElementById('msg');
  msg.textContent = 'Connecting...';
  try {
    const res = await fetch('/api/connect', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ ssid, password, country })
    });
    const data = await res.json();
    if (data.ok) {
      msg.textContent = 'Connected! The device will reboot.';
    } else {
      msg.textContent = 'Failed: ' + (data.error || 'unknown error');
    }
  } catch (e) {
    msg.textContent = 'Request error';
  }
});

window.addEventListener('load', loadNetworks);
