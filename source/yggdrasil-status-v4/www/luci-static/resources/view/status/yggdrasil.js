'use strict';
'require view';
'require rpc';
'require uci';
'require poll';
'require ui';


var callInterfaces = rpc.declare({
	object: 'network.interface',
	method: 'dump',
	expect: { interface: [] }
});


var callPeers = rpc.declare({
	object: 'luci.yggdrasil',
	method: 'getPeers',
	params: [ 'interface' ],
	expect: { peers: [] }
});


var callClients = rpc.declare({
	object: 'luci.yggdrasil-status',
	method: 'clients',
	expect: { clients: [] }
});


var callPin = rpc.declare({
	object: 'luci.yggdrasil-status',
	method: 'pin',
	params: [ 'mac', 'name', 'reserve_ipv4' ]
});


var callUnpin = rpc.declare({
	object: 'luci.yggdrasil-status',
	method: 'unpin',
	params: [ 'mac', 'confirm_static' ]
});


function cleanURI(uri) {
	return uri ? String(uri).replace(/\?.*$/, '') : '—';
}


function dataUnit(value) {
	return value != null
		? '%.2mB'.format(value)
		: '—';
}


function rate(value) {
	return value > 0
		? '%.2mB/s'.format(value)
		: '—';
}


function lastError(peer) {
	if (peer.up || !peer.last_error)
		return '—';

	if (peer.last_error_time)
		return '%t ago: %s'.format(
			peer.last_error_time,
			peer.last_error
		);

	return peer.last_error;
}


function makeTable(headers, rows, id, compactColumns) {
	var attrs = { 'class': 'table' };
	var compact = compactColumns || [];

	if (id)
		attrs.id = id;

	var table = E('table', attrs, [
		E('tr', { 'class': 'tr table-titles' },
			headers.map(function(header, i) {
				return E('th', {
					'class': 'th',
					'style': compact.indexOf(i) !== -1
						? 'width: 1%; white-space: nowrap; text-align: center'
						: null
				}, header);
			})
		)
	]);

	rows.forEach(function(row) {
			table.appendChild(E('tr', { 'class': 'tr' },
			row.map(function(value, i) {
				var isCompact = compact.indexOf(i) !== -1;

				return E('td', {
					'class': 'td',
					'data-title': headers[i],
					'style': isCompact
						? 'width: 1%; white-space: nowrap; text-align: center; word-break: normal'
						: 'word-break: break-word'
				}, value == null || value === '' ? '—' : value);
			})
		));
	});

	return table;
}


function ipv6Cell(client) {
	var addresses = Array.isArray(client.ipv6_addresses)
		? client.ipv6_addresses.slice()
		: [];

	if (!addresses.length && client.ipv6)
		addresses.push(client.ipv6);

	if (!addresses.length)
		return '—';

	return E('div', {}, addresses.map(function(addr) {
		var attrs = {};

		if (client.canonical_ipv6 && addr === client.canonical_ipv6) {
			attrs.style = 'font-weight: 600';
			attrs.title = _('Canonical address');
		}

		return E('div', attrs, addr);
	}));
}


function backendError(result) {
	return result && result.message
		? result.message
		: _('The operation failed.');
}


function notifyError(message) {
	ui.addNotification(null, E('p', {}, message), 'error');
}


function refreshClients() {
	return callClients().then(function(clients) {
		replaceClientTable(clients || []);
		return clients;
	});
}


function validHostname(name) {
	return /^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$/.test(name);
}


function showPinDialog(client) {
	var initialName = client.hostname || '';
	var nameInput = E('input', {
		'class': 'cbi-input-text',
		'type': 'text',
		'value': initialName,
		'placeholder': _('Device hostname'),
		'maxlength': 63,
		'style': 'width: 100%'
	});

	var reserveAttrs = { 'type': 'checkbox' };

	if (!client.ipv4)
		reserveAttrs.disabled = '';

	var reserveInput = E('input', reserveAttrs);

	var errorBox = E('div', {
		'style': 'display:none; color:#dc2626; margin-top:.5em'
	});

	var saveButton;

	function showError(message) {
		errorBox.textContent = message;
		errorBox.style.display = '';
	}

	saveButton = E('button', {
		'class': 'btn cbi-button-positive important',
		'click': function(ev) {
			ev.preventDefault();

			var name = String(nameInput.value || '').trim();
			var reserve = !!reserveInput.checked;

			if (!validHostname(name)) {
				showError(_('Hostname must be 1-63 characters using letters, digits or hyphens, and cannot start or end with a hyphen.'));
				return;
			}

			errorBox.style.display = 'none';
			saveButton.disabled = true;

			callPin(client.mac, name, reserve)
				.then(function(result) {
					if (!result || !result.ok) {
						showError(backendError(result));
						saveButton.disabled = false;
						return;
					}

					ui.hideModal();
					return refreshClients();
				})
				.catch(function(err) {
					showError(err.message || String(err));
					saveButton.disabled = false;
				});
		}
	}, _('Save'));

	ui.showModal(_('Pin device'), [
		E('p', {}, _('Pinning creates a normal OpenWrt config host entry so this device remains visible after its DHCP lease expires.')),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Hostname')),
			E('div', { 'class': 'cbi-value-field' }, nameInput)
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('IPv4 reservation')),
			E('div', { 'class': 'cbi-value-field' }, [
				E('label', {}, [
					reserveInput,
					' ',
					client.ipv4
						? _('Reserve current IPv4 %s').format(client.ipv4)
						: _('No current IPv4 address is available')
				])
			])
		]),
		E('p', {}, _('The IPv4 reservation is optional and is disabled by default.')),
		errorBox,
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Cancel')),
			' ',
			saveButton
		])
	]);

	nameInput.focus();
}


function performUnpin(client, confirmStatic, errorBox, button) {
	button.disabled = true;

	return callUnpin(client.mac, !!confirmStatic)
		.then(function(result) {
			if (result && result.code === 'static_confirmation_required') {
				ui.hideModal();
				client.static_ipv4 = 1;
				client.reserved_ipv4 = result.reserved_ipv4 || client.reserved_ipv4 || client.ipv4 || '';
				showUnpinDialog(client);
				return;
			}

			if (!result || !result.ok) {
				errorBox.textContent = backendError(result);
				errorBox.style.display = '';
				button.disabled = false;
				return;
			}

			ui.hideModal();
			return refreshClients();
		})
		.catch(function(err) {
			errorBox.textContent = err.message || String(err);
			errorBox.style.display = '';
			button.disabled = false;
		});
}


function showUnpinDialog(client) {
	var errorBox = E('div', {
		'style': 'display:none; color:#dc2626; margin-top:.5em'
	});
	var paragraphs = [];
	var confirmStatic = !!client.static_ipv4;
	var actionLabel = _('Unpin');
	var actionButton;

	paragraphs.push(E('p', {}, _('After unpinning, the device remains in the table only while an active DHCP lease exists.')));

	if (!client.managed_pin) {
		paragraphs.push(E('p', {}, _('This persistent entry is an existing OpenWrt config host record, not one created by the Yggdrasil status Pin button. Unpinning removes that config host section from /etc/config/dhcp.')));
	}

	if (client.shared_host) {
		paragraphs.push(E('p', { 'style': 'color:#dc2626; font-weight:600' }, _('This config host contains multiple MAC addresses. It cannot be safely removed from this page. Use Network -> DHCP and DNS to edit it manually.')));
	}

	if (confirmStatic) {
		paragraphs.push(E('p', { 'style': 'color:#dc2626; font-weight:600' },
			_('This device has a static DHCP reservation. Removing this persistent entry will also remove the reserved IPv4 address %s.').format(client.reserved_ipv4 || client.ipv4 || '—')
		));
		actionLabel = _('Unpin and remove reservation');
	}

	paragraphs.push(E('p', {}, _('Any separate config domain canonical IPv6 / DNS record is left untouched.')));

	var actionAttrs = {
		'class': 'btn cbi-button-negative important',
		'click': function(ev) {
			ev.preventDefault();
			performUnpin(client, confirmStatic, errorBox, actionButton);
		}
	};

	if (client.shared_host)
		actionAttrs.disabled = '';

	actionButton = E('button', actionAttrs, actionLabel);

	ui.showModal(_('Unpin device'), paragraphs.concat([
		errorBox,
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Cancel')),
			' ',
			actionButton
		])
	]));
}


function showProtectedHostDialog(client) {
	var reasons = [];

	if (client.shared_host)
		reasons.push(_('the config host contains multiple MAC addresses'));

	if (client.ambiguous_host)
		reasons.push(_('this MAC appears in more than one config host section'));

	if (client.complex_host)
		reasons.push(_('the config host contains additional DHCP options'));

	ui.showModal(_('Manage persistent device'), [
		E('p', {}, _('This device is persistent, but the Yggdrasil status page will not delete its OpenWrt config host automatically.')),
		E('p', { 'style': 'font-weight:600' }, reasons.length
			? _('Reason: %s.').format(reasons.join('; '))
			: _('The host record requires manual review.')),
		E('p', {}, _('Use Network -> DHCP and DNS to edit or remove this host record safely.')),
		E('p', {}, _('Any separate config domain canonical IPv6 / DNS record is independent and is not changed here.')),
		E('div', { 'class': 'right' }, [
			E('button', {
				'class': 'btn cbi-button-positive important',
				'click': function(ev) {
					ev.preventDefault();
					ui.hideModal();
				}
			}, _('Close'))
		])
	]);
}


function persistenceCell(client) {
	var label;
	var button;

	if (!client.persistent) {
		label = E('span', { 'style': 'font-weight:600' }, _('Dynamic'));
		button = E('button', {
			'class': 'btn cbi-button-action',
			'style': 'width:100%',
			'click': function(ev) {
				ev.preventDefault();
				showPinDialog(client);
			}
		}, _('Pin'));
	}
	else {
		label = E('span', { 'style': 'font-weight:600' },
			client.static_ipv4
				? _('Static')
				: (client.managed_pin ? _('Pinned') : _('Persistent')));

		if (client.protected_host) {
			button = E('button', {
				'class': 'btn cbi-button-action',
				'style': 'width:100%',
				'click': function(ev) {
					ev.preventDefault();
					showProtectedHostDialog(client);
				}
			}, _('Manage'));
		}
		else {
			button = E('button', {
				'class': 'btn cbi-button-action',
				'style': 'width:100%',
				'click': function(ev) {
					ev.preventDefault();
					showUnpinDialog(client);
				}
			}, client.static_ipv4 ? _('Manage') : _('Unpin'));
		}
	}

	return E('div', {
		'style': 'display:grid; grid-template-columns:6em 5.5em; gap:.5em; align-items:center; white-space:nowrap'
	}, [ label, button ]);
}


function makeClientTable(clients) {
	var headers = [
		_('Hostname'),
		_('MAC'),
		_('IPv4'),
		_('Yggdrasil IPv6'),
		_('DNS'),
		_('State'),
		_('Persistence')
	];

	var rows = (clients || []).map(function(client) {
		return [
			client.hostname || '—',
			client.mac || '—',
			client.ipv4 || '—',
			ipv6Cell(client),
			client.dns || '—',
			client.online
				? E('span', { 'style': 'color: #16a34a; font-weight: 600' }, _('Online'))
				: E('span', { 'style': 'color: #dc2626; font-weight: 600' }, _('Offline')),
			persistenceCell(client)
		];
	});

	rows.sort(function(a, b) {
		return String(a[0]).localeCompare(String(b[0]));
	});

	return makeTable(headers, rows, 'yggdrasil-lan-clients');
}


function replaceClientTable(clients) {
	var oldTable = document.getElementById('yggdrasil-lan-clients');

	if (!oldTable)
		return;

	var newTable = makeClientTable(clients);
	oldTable.parentNode.replaceChild(newTable, oldTable);
}


return view.extend({
	load: function() {
		return Promise.all([
			callInterfaces(),
			callClients(),
			uci.load('network')
		]).then(function(data) {
			var interfaces = (data[0] || []).filter(function(iface) {
				return iface.proto === 'yggdrasil';
			});

			return Promise.all(interfaces.map(function(iface) {
				return callPeers(iface.interface).catch(function() {
					return [];
				});
			})).then(function(peers) {
				return {
					interfaces: interfaces,
					clients: data[1] || [],
					peers: peers
				};
			});
		});
	},


	render: function(data) {
		var interfaces = data.interfaces;

		if (!interfaces.length)
			return E([
				E('h2', {}, _('Yggdrasil')),
				E('em', {}, _('No Yggdrasil interface found.'))
			]);

		var nodeRows = [];

		interfaces.forEach(function(iface) {
			var address = (iface['ipv6-address'] || [])[0];

			var subnet = (iface['ipv6-prefix'] || []).find(function(p) {
				return p.class === 'ygg';
			});

			var publicKey =
				uci.get('network', iface.interface, 'public_key') || '—';

			nodeRows.push([
				iface.interface,
				iface.up ? _('Up') : _('Down'),
				address ? address.address : '—',
				subnet ? subnet.address + '/' + subnet.mask : '—',
				publicKey,
				iface.up ? '%t'.format(iface.uptime || 0) : '—'
			]);
		});

		var peerRows = [];

		interfaces.forEach(function(iface, index) {
			(data.peers[index] || []).forEach(function(peer) {
				peerRows.push([
					iface.interface,
					cleanURI(peer.remote),
					peer.up ? _('Up') : _('Down'),
					peer.inbound ? _('In') : _('Out'),
					peer.address || '—',
					peer.up ? '%t'.format(peer.uptime || 0) : '—',
					peer.up && peer.latency
						? '%.2f ms'.format(peer.latency / 1000000)
						: '—',
					dataUnit(peer.bytes_recvd),
					dataUnit(peer.bytes_sent),
					rate(peer.rate_recvd),
					rate(peer.rate_sent),
					peer.priority != null ? String(peer.priority) : '—',
					peer.cost != null ? String(peer.cost) : '—',
					lastError(peer)
				]);
			});
		});

		var content = [
			E('h2', {}, _('Yggdrasil')),
			E('h3', {}, _('Node')),
			makeTable(
				[
					_('Interface'),
					_('State'),
					_('Yggdrasil address'),
					_('Routed subnet'),
					_('Public key'),
					_('Uptime')
				],
				nodeRows,
				null,
				[1]
			),
			E('h3', {}, _('Peers'))
		];

		if (peerRows.length) {
			content.push(makeTable(
				[
					_('Interface'),
					_('URI'),
					_('State'),
					_('Dir'),
					_('IP Address'),
					_('Uptime'),
					_('RTT'),
					_('RX'),
					_('TX'),
					_('Down'),
					_('Up'),
					_('Pr'),
					_('Cost'),
					_('Last Error')
				],
				peerRows,
				null,
				[2, 3, 11, 12]
			));
		}
		else {
			content.push(E('em', {}, _('No peers found.')));
		}

		content.push(
			E('h3', {}, _('LAN clients')),
			makeClientTable(data.clients)
		);

		/*
		 * Dynamic rows live for the DHCP lease lifetime; persistent config-host
		 * rows remain. Pin/Unpin modifies only config host records. Polling runs
		 * only while this page is open and refreshes the LAN table every 15 sec.
		 */
		poll.add(function() {
			return refreshClients().catch(function() {});
		}, 15);

		return E(content);
	},


	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
