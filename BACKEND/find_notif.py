with open('BACKEND/main.py', 'r', encoding='utf-8') as f:
    for idx, line in enumerate(f, 1):
        if 'Notifications' in line or 'notifications' in line:
            print(f'{idx}: {line.strip()}')

