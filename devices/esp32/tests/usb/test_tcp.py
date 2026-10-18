"""Production C server over localhost; no USB enumeration or real HID input."""
import os, pathlib, signal, socket, subprocess, time, unittest
ROOT = pathlib.Path(__file__).resolve().parents[4]

class TCPContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0)); cls.port=reservation.getsockname()[1]
        cls.server = subprocess.Popen([str(ROOT / '.build/usb-device-tests/server')], env={**os.environ, 'PA_TEST_HID':'1', 'PA_TEST_PORT':str(cls.port)})
        for _ in range(100):
            try:
                probe=socket.create_connection(('127.0.0.1',cls.port), timeout=.1)
                probe.recv(256); probe.close(); time.sleep(.1); return
            except ConnectionRefusedError:
                if cls.server.poll() is not None: break
                time.sleep(.05)
        cls.server.terminate(); cls.server.wait(timeout=2)
        raise RuntimeError('host test server failed to start')
    @classmethod
    def tearDownClass(cls):
        cls.server.terminate(); cls.server.wait(timeout=2)
    def setUp(self):
        time.sleep(.1)
        self.sock = socket.create_connection(('127.0.0.1',self.port), timeout=2)
        self.stream = self.sock.makefile('rb')
        self.addCleanup(self.sock.close)
        self.addCleanup(self.stream.close)
        self.assertEqual(self.stream.readline(), b'PA3 READY 1\n')
    def send(self, body):
        self.sock.sendall(f'{body}\n'.encode('ascii'))
    def read_ack(self):
        line = self.stream.readline()
        self.assertTrue(line.endswith(b'\n'))
        return line[:-1].decode('ascii')
    def test_ping_tap_duplicate_and_conflicting_id(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 TAP 1 65535 0'); self.assertEqual(self.read_ack(),'2 received'); self.assertEqual(self.read_ack(),'2 executed')
        self.send('2 TAP 1 65535 0'); self.assertEqual(self.read_ack(),'2 executed')
        self.send('2 TAP 1 0 0'); self.assertEqual(self.stream.readline(),b'')
    def test_drag_ack_and_ping_multiplexing(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 1 0 0 65535 65535 250'); self.assertEqual(self.read_ack(),'2 received')
        self.send('3 PING'); self.assertEqual(self.read_ack(),'3 executed')
        self.assertEqual(self.read_ack(),'2 executed')
    def test_missing_heartbeat_revokes_active_input(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 1 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.assertEqual(self.stream.readline(),b'')
    def test_stop_releases_and_reuses_connection_for_next_task(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 1 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.send('3 STOP 1')
        self.assertEqual(self.read_ack(),'2 cancelled'); self.assertEqual(self.read_ack(),'3 executed')
        self.send('4 PING'); self.assertEqual(self.read_ack(),'4 executed')
        self.send('5 TAP 2 10 20'); self.assertEqual(self.read_ack(),'5 received'); self.assertEqual(self.read_ack(),'5 executed')
        self.send('6 STOP 2'); self.assertEqual(self.read_ack(),'6 executed')
        self.send('7 PING'); self.assertEqual(self.read_ack(),'7 executed')
    def test_consecutive_stop_id2_id3_preserve_both_terminal_results(self):
        # Original audit was two STOP commands (IDs 2 and 3), repeated five
        # times, not five STOP commands with only three successful receipts.
        self.send('1 PING'); self.assertEqual(self.read_ack(), '1 executed')
        self.sock.sendall(b'2 STOP 1\n3 STOP 1\n')
        self.assertCountEqual([self.read_ack(), self.read_ack()], ['2 executed', '3 cancelled'])
        self.send('4 PING'); self.assertEqual(self.read_ack(), '4 executed')
    def stop_with_pipelined_commands(self, tail, expected):
        self.send('1 PING'); self.assertEqual(self.read_ack(), '1 executed')
        self.send('2 DRAG 1 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(), '2 received')
        self.sock.sendall(b'3 STOP 1\n' + tail)
        replies=[self.read_ack() for _ in range(len(expected))]
        self.assertCountEqual(replies,expected)
        self.assertLess(replies.index('2 cancelled'),replies.index('3 executed'))
        self.send('10 PING'); self.assertEqual(self.read_ack(),'10 executed')
        self.send('11 TAP 2 3 4'); self.assertEqual(self.read_ack(),'11 received'); self.assertEqual(self.read_ack(),'11 executed')
    def test_first_stop_owns_release_when_later_stop_is_pipelined(self):
        self.stop_with_pipelined_commands(b'4 STOP 1\n', ['2 cancelled','3 executed','4 cancelled'])
    def test_duplicate_pending_stop_never_reports_received(self):
        self.stop_with_pipelined_commands(b'3 STOP 1\n', ['2 cancelled','3 executed'])
    def test_stop_drains_ping_and_cancels_pipelined_old_input(self):
        self.stop_with_pipelined_commands(b'4 PING\n5 TAP 1 0 0\n', ['2 cancelled','3 executed','4 executed','5 cancelled'])
    def test_release_in_progress_rejects_even_next_generation_input_and_stop(self):
        self.stop_with_pipelined_commands(b'4 STOP 2\n5 TAP 2 0 0\n', ['2 cancelled','3 executed','4 cancelled','5 cancelled'])
    def test_release_timeout_closes_without_success_ack(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 1 0 0 1 1 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.server.send_signal(signal.SIGUSR2)
        try:
            self.send('3 STOP 1'); self.assertEqual(self.stream.readline(), b'')
        finally:
            self.server.send_signal(signal.SIGUSR2)
    def test_generation_change_rejects_late_old_input_and_stop(self):
        self.send('1 STOP 1'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 PING'); self.assertEqual(self.read_ack(),'2 executed')
        self.send('3 TAP 1 0 0'); self.assertEqual(self.read_ack(),'3 cancelled')
        self.send('4 STOP 1'); self.assertEqual(self.read_ack(),'4 cancelled')
        self.send('5 TAP 2 10 20'); self.assertEqual(self.read_ack(),'5 received'); self.assertEqual(self.read_ack(),'5 executed')
    def test_duplicate_stop_and_cancelled_input_keep_terminal_receipts(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 1 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.send('3 STOP 1'); self.assertEqual(self.read_ack(),'2 cancelled'); self.assertEqual(self.read_ack(),'3 executed')
        self.send('2 DRAG 1 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 cancelled')
        self.send('3 STOP 1'); self.assertEqual(self.read_ack(),'3 executed')
        self.send('4 PING'); self.assertEqual(self.read_ack(),'4 executed')
        self.send('5 TAP 2 1 2'); self.assertEqual(self.read_ack(),'5 received'); self.assertEqual(self.read_ack(),'5 executed')
    def test_cancelled_action_does_not_pin_dedup_ring_forever(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 1 0 0 1 1 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.send('3 STOP 1'); self.assertEqual(self.read_ack(),'2 cancelled'); self.assertEqual(self.read_ack(),'3 executed')
        for command_id in range(4,80):
            self.send(f'{command_id} PING'); self.assertEqual(self.read_ack(),f'{command_id} executed')
        self.send('80 TAP 2 0 0'); self.assertEqual(self.read_ack(),'80 received'); self.assertEqual(self.read_ack(),'80 executed')
    def test_old_unscoped_protocol_is_rejected(self):
        self.send('1 STOP'); self.assertEqual(self.stream.readline(), b'')
    def test_bus_epoch_change_revokes_session(self):
        self.send('1 PING'); self.assertEqual(self.read_ack(),'1 executed')
        self.send('2 DRAG 1 0 0 65535 65535 2000'); self.assertEqual(self.read_ack(),'2 received')
        self.server.send_signal(signal.SIGUSR1)
        self.assertEqual(self.stream.readline(),b'')
    def test_old_signed_command_never_accepted(self):
        self.sock.sendall(('1 TAP 1 0 0 '+'0'*64+'\n').encode())
        self.assertEqual(self.stream.readline(),b'')
    def test_oversized_line_closes(self):
        self.sock.sendall(b'A'*257+b'\n'); self.assertEqual(self.stream.readline(),b'')
    def test_input_requires_ping_on_each_connection(self):
        self.send('1 TAP 1 0 0'); self.assertEqual(self.read_ack(), '1 cancelled')
    def test_fragmented_and_coalesced_lines(self):
        self.sock.sendall(b'1 PI'); self.sock.sendall(b'NG\n2 PING\n')
        self.assertEqual(self.read_ack(), '1 executed'); self.assertEqual(self.read_ack(), '2 executed')
    def test_retired_id_does_not_reexecute(self):
        for command_id in range(1, 35):
            self.send(f'{command_id} PING'); self.assertEqual(self.read_ack(), f'{command_id} executed')
        self.send('1 PING'); self.assertEqual(self.stream.readline(), b'')

class NCMOnly(unittest.TestCase):
    def start(self):
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1',0)); port=reservation.getsockname()[1]
        env={**os.environ,'PA_TEST_PORT':str(port)}
        env.pop('PA_TEST_HID',None)
        server=subprocess.Popen([str(ROOT / '.build/usb-device-tests/server')],env=env)
        def cleanup():
            server.terminate(); server.wait(timeout=2)
        self.addCleanup(cleanup)
        for _ in range(100):
            try:
                conn=socket.create_connection(('127.0.0.1',port),timeout=2)
                self.addCleanup(conn.close)
                stream=conn.makefile('rb'); self.addCleanup(stream.close)
                return conn,stream
            except ConnectionRefusedError:
                if server.poll() is not None: break
                time.sleep(.05)
        self.fail('server did not start')
    def test_no_credentials_needed_for_ping_and_stop(self):
        conn,stream=self.start()
        self.assertEqual(stream.readline(), b'PA3 READY 0\n')
        conn.sendall(b'1 PING\n'); self.assertEqual(stream.readline(), b'1 executed\n')
        conn.sendall(b'2 STOP 1\n'); self.assertEqual(stream.readline(), b'2 executed\n')
        conn.sendall(b'3 PING\n'); self.assertEqual(stream.readline(),b'3 executed\n')
    def test_ncm_only_preserves_first_stop_receipt(self):
        conn,stream=self.start()
        self.assertEqual(stream.readline(), b'PA3 READY 0\n')
        conn.sendall(b'1 STOP 1\n2 STOP 1\n')
        self.assertCountEqual([stream.readline(), stream.readline()], [b'1 executed\n', b'2 cancelled\n'])
        conn.sendall(b'3 PING\n'); self.assertEqual(stream.readline(), b'3 executed\n')
    def test_ncm_only_rejects_input_after_ping(self):
        conn,stream=self.start()
        self.assertEqual(stream.readline(), b'PA3 READY 0\n')
        conn.sendall(b'1 PING\n'); self.assertEqual(stream.readline(), b'1 executed\n')
        conn.sendall(b'2 TAP 1 0 0\n'); self.assertEqual(stream.readline(), b'2 cancelled\n')
    def test_old_authentication_request_is_rejected(self):
        conn,stream=self.start(); self.assertEqual(stream.readline(), b'PA3 READY 0\n')
        conn.sendall(('PA1 AUTH '+'0'*64+'\n').encode())
        self.assertEqual(stream.readline(),b'')
    def test_malformed_lines_close_session(self):
        for line in [b'01 PING\n', b'1 PING \n', b'1 PING\r\n', b'1\tPING\n', b'1 PING\x00\n']:
            with self.subTest(line=line):
                conn,stream=self.start(); self.assertEqual(stream.readline(), b'PA3 READY 0\n')
                conn.sendall(line); self.assertEqual(stream.readline(), b'')

if __name__ == '__main__': unittest.main(verbosity=2)
