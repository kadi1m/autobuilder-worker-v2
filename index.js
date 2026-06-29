const WebSocket = require('ws');
const { exec, spawn } = require('child_process');
const os = require('os');
const si = require('systeminformation');
const Docker = require('dockerode');
const pty = require('node-pty');

const docker = new Docker();

// In production, these should be loaded from .env
const CONTROL_PLANE_HOST = process.env.CONTROL_PLANE_HOST || 'localhost:3000';
const NODE_ID = process.env.NODE_ID || os.hostname();

const ws = new WebSocket(`ws://${CONTROL_PLANE_HOST}/worker/ws?nodeId=${NODE_ID}`);

console.log(`[Worker] Connecting to ws://${CONTROL_PLANE_HOST}/worker/ws?nodeId=${NODE_ID}`);

const containerLogStreams = {};
const containerPtySessions = {};

setInterval(() => {
    if (ws.readyState === WebSocket.OPEN) {
        ws.ping();
    }
}, 15000);

ws.on('open', function open() {
    console.log('[Worker] Connected to Control Plane');
    ws.send(JSON.stringify({ type: 'status', payload: 'idle' }));
});

ws.on('message', async function message(data) {
    const msgStr = data.toString();
    
    try {
        const msg = JSON.parse(msgStr);

        // --- LIVE LOGS HANDLING ---
        if (msg.type === 'start_container_log') {
            const containerName = msg.payload?.container_name;
            if (!containerName || containerLogStreams[containerName]) return;

            console.log(`[Worker] Starting live log stream for container: ${containerName}`);
            const logProcess = spawn('docker', ['logs', '-f', '--tail', '100', containerName]);
            containerLogStreams[containerName] = logProcess;

            const sendLogData = (data) => {
                if (ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({
                        type: 'container_log',
                        payload: { container_name: containerName, data: data.toString() }
                    }));
                }
            };

            logProcess.stdout.on('data', sendLogData);
            logProcess.stderr.on('data', sendLogData);

            logProcess.on('close', () => {
                delete containerLogStreams[containerName];
            });
            return;
        }

        if (msg.type === 'stop_container_log') {
            const containerName = msg.payload?.container_name;
            if (containerName && containerLogStreams[containerName]) {
                console.log(`[Worker] Stopping live log stream for container: ${containerName}`);
                containerLogStreams[containerName].kill();
                delete containerLogStreams[containerName];
            }
            return;
        }

        // --- INTERACTIVE TERMINAL (EXEC) HANDLING ---
        if (msg.type === 'start_exec') {
            const { container_name, session_id, cols = 80, rows = 24 } = msg.payload;
            if (!container_name || !session_id) return;

            console.log(`[Worker] Starting PTY session ${session_id} for container: ${container_name}`);
            
            // Spawn an interactive bash session inside the container
            const ptyProcess = pty.spawn('docker', ['exec', '-it', container_name, '/bin/bash'], {
                name: 'xterm-color',
                cols: cols,
                rows: rows,
                cwd: process.env.HOME,
                env: process.env
            });

            containerPtySessions[session_id] = ptyProcess;

            // When PTY writes out, send it to the control plane
            ptyProcess.onData((data) => {
                if (ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({
                        type: 'exec_output',
                        payload: { session_id, data }
                    }));
                }
            });

            // When PTY exits naturally (user types exit)
            ptyProcess.onExit(({ exitCode }) => {
                console.log(`[Worker] PTY session ${session_id} exited with code ${exitCode}`);
                if (ws.readyState === WebSocket.OPEN) {
                    ws.send(JSON.stringify({
                        type: 'exec_exit',
                        payload: { session_id, exitCode }
                    }));
                }
                delete containerPtySessions[session_id];
            });
            return;
        }

        // Input received from the user's terminal UI, pipe it into the PTY
        if (msg.type === 'exec_input') {
            const { session_id, data } = msg.payload;
            if (containerPtySessions[session_id]) {
                containerPtySessions[session_id].write(data);
            }
            return;
        }
        
        // Resize the terminal
        if (msg.type === 'exec_resize') {
            const { session_id, cols, rows } = msg.payload;
            if (containerPtySessions[session_id]) {
                containerPtySessions[session_id].resize(cols, rows);
            }
            return;
        }

        // Force stop terminal
        if (msg.type === 'stop_exec') {
            const { session_id } = msg.payload;
            if (containerPtySessions[session_id]) {
                containerPtySessions[session_id].kill();
                delete containerPtySessions[session_id];
            }
            return;
        }

    } catch (err) {
        // Ignore unparseable messages
    }
});

ws.on('error', (err) => {
    console.error('[Worker] WebSocket error:', err.message);
});

ws.on('close', () => {
    console.log('[Worker] Disconnected from Control Plane. Retrying in 5s...');
    setTimeout(() => process.exit(1), 5000); // Will rely on PM2/Docker to restart
});

// Stats Collection (Same as V1)
async function collectStats() {
    try {
        const [cpu, mem, fs, net, containers] = await Promise.all([
            si.currentLoad(), si.mem(), si.fsSize(), si.networkStats(), docker.listContainers()
        ]);

        const diskPct = fs.length > 0 ? fs[0].use : 0;
        const netRx = net.length > 0 ? net[0].rx_bytes : 0;
        const netTx = net.length > 0 ? net[0].tx_bytes : 0;

        let dockerStats = [];
        for (const container of containers) {
            try {
                const c = docker.getContainer(container.Id);
                const stats = await c.stats({ stream: false });
                
                let cpuPct = 0;
                if (stats.cpu_stats && stats.precpu_stats) {
                    const cpuDelta = stats.cpu_stats.cpu_usage.total_usage - stats.precpu_stats.cpu_usage.total_usage;
                    const systemDelta = stats.cpu_stats.system_cpu_usage - stats.precpu_stats.system_cpu_usage;
                    if (systemDelta > 0.0 && cpuDelta > 0.0) {
                        cpuPct = (cpuDelta / systemDelta) * stats.cpu_stats.online_cpus * 100.0;
                    }
                }
                
                const memUsage = stats.memory_stats?.usage || 0;
                dockerStats.push({
                    id: container.Id.substring(0, 12),
                    name: container.Names[0],
                    cpu_pct: cpuPct,
                    mem_usage: memUsage,
                });
            } catch (err) {}
        }

        const payload = {
            node_id: NODE_ID,
            cpu: cpu.currentLoad,
            mem: (mem.active / mem.total) * 100,
            disk_pct: diskPct,
            net_rx: netRx,
            net_tx: netTx,
            docker_stats: dockerStats
        };

        const res = await fetch(`http://${CONTROL_PLANE_HOST}/worker/stats`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
    } catch (err) {
        console.error(`[Worker] Error collecting stats:`, err.message);
    }
}

setInterval(collectStats, 30000);
setTimeout(collectStats, 2000);
