import socket, threading, select

# CONFIGURACION
LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 80
PASS = ''

# PUERTO SSH LOCAL
SSH_ADDR = '127.0.0.1'
SSH_PORT = 22

def handler(sock, addr):
    try:
        data = sock.recv(1024).decode('utf-8')
        if not data: return
        
        # Respuesta para que el Injector sepa que el túnel está abierto
        if 'Upgrade: websocket' in data or 'CONNECT' in data:
            # Respondemos con el código 101 que pide el WebSocket
            sock.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
            
            # Conectamos al SSH interno
            target = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            target.connect((SSH_ADDR, SSH_PORT))
            
            # Puente de datos entre Celular <-> VPS <-> SSH
            sockets = [sock, target]
            while True:
                readable, writable, err = select.select(sockets, [], sockets, 3)
                if err: break
                for s in readable:
                    out = s.recv(4096)
                    if not out: break
                    if s is sock:
                        target.sendall(out)
                    else:
                        sock.sendall(out)
                if not out: break
    except:
        pass
    finally:
        sock.close()

def main():
    print(f"--- PROXY WEBSOCKET TITO MX ACTIVO EN PUERTO {LISTENING_PORT} ---")
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((LISTENING_ADDR, LISTENING_PORT))
    server.listen(100)
    
    while True:
        client, addr = server.accept()
        threading.Thread(target=handler, args=(client, addr)).start()

if __name__ == '__main__':
    main()
