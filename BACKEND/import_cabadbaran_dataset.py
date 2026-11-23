import csv
import os
import sys
from datetime import datetime
import psycopg
import sqlite3
from dotenv import dotenv_values

CSV_PATH = r"C:/Users/LENOVO/.gemini/antigravity/brain/35ebd3e5-e9a8-4a2a-91fd-d9cf009cc7aa/.user_uploaded/media_1795394744240_669fa4bb.csv"

env = dotenv_values('BACKEND/.env')
PG_URL = env.get('DATABASE_URL', 'postgresql://postgres:Password123@localhost:5432/cbr_citizensence')

print(f"Reading CSV from {CSV_PATH}...")
with open(CSV_PATH, 'r', encoding='utf-8', errors='replace') as f:
    reader = csv.DictReader(f)
    rows = list(reader)

print(f"Total rows in CSV: {len(rows)}")
print(f"Columns: {list(rows[0].keys())}")

# 1. Update PostgreSQL nyc_311_complaints
print("\n--- Connecting to PostgreSQL ---")
try:
    pg_conn = psycopg.connect(PG_URL)
    with pg_conn.cursor() as cur:
        # Check and add any missing columns in nyc_311_complaints
        cur.execute("SELECT column_name FROM information_schema.columns WHERE table_name = 'nyc_311_complaints';")
        existing_cols = {r[0] for r in cur.fetchall()}
        
        needed_cols = [
            ('agency_code', 'TEXT'),
            ('barangay', 'TEXT'),
            ('purok', 'TEXT'),
            ('province', 'TEXT'),
            ('zip_code', 'TEXT'),
            ('resolution_updated_date', 'TEXT'),
            ('channel', 'TEXT'),
        ]
        for col, col_type in needed_cols:
            if col not in existing_cols:
                print(f"Adding column {col} to nyc_311_complaints...")
                cur.execute(f"ALTER TABLE nyc_311_complaints ADD COLUMN IF NOT EXISTS {col} {col_type};")
        
        # Clear previous records per user instruction
        print("Clearing old records from nyc_311_complaints...")
        cur.execute("TRUNCATE TABLE nyc_311_complaints;")
        
        # Insert into nyc_311_complaints
        insert_nyc_sql = """
            INSERT INTO nyc_311_complaints (
                unique_key, created_date, closed_date, agency, agency_code, agency_name,
                complaint_type, descriptor, location_type, incident_zip, zip_code,
                incident_address, street_name, cross_street_1, cross_street_2,
                address_type, barangay, purok, landmark, city, province, status,
                resolution_description, resolution_action_updated_date, resolution_updated_date,
                open_data_channel_type, channel, latitude, longitude
            ) VALUES (
                %(unique_key)s, %(created_date)s, %(closed_date)s, %(agency_code)s, %(agency_code)s, %(agency_name)s,
                %(complaint_type)s, %(descriptor)s, %(location_type)s, %(zip_code)s, %(zip_code)s,
                %(incident_address)s, %(street_name)s, %(cross_street_1)s, %(cross_street_2)s,
                %(address_type)s, %(barangay)s, %(purok)s, %(landmark)s, %(city)s, %(province)s, %(status)s,
                %(resolution_description)s, %(resolution_updated_date)s, %(resolution_updated_date)s,
                %(channel)s, %(channel)s, %(latitude)s, %(longitude)s
            );
        """
        cur.executemany(insert_nyc_sql, rows)
        pg_conn.commit()
        print(f"✅ Successfully inserted {len(rows)} rows into PostgreSQL nyc_311_complaints!")

        # Check offices mapping
        cur.execute("SELECT office_id, office_name FROM offices_tbl;")
        offices = cur.fetchall()
        print(f"Offices in DB: {offices}")
        
        # Check users in DB to get a valid citizen user_id
        cur.execute("SELECT id, role, email FROM citizensense_users ORDER BY id LIMIT 5;")
        users = cur.fetchall()
        print(f"Users in DB: {users}")
        default_user_id = users[0][0] if users else 1

        # Also populate complaints_tbl
        print("\n--- Populating complaints_tbl in PostgreSQL ---")
        cur.execute("TRUNCATE TABLE complaints_tbl RESTART IDENTITY CASCADE;")
        
        # Build mapping for offices
        # Map agency codes:
        # CEO -> 1 (City Engineering Office)
        # CHO -> 2 (City Health Office)
        # CENRO -> 3 (CENRO)
        # CSWDO -> 4 (CSWDO)
        # CDRRMO -> 5 (CDRRMO)
        # CPS / PSO -> 6 (PSO)
        # BPLO, CWD, OBO, etc. -> 7 (Mayor's Office / General Concerns)
        agency_office_map = {
            'CEO': 1,
            'CHO': 2,
            'CENRO': 3,
            'CSWDO': 4,
            'CDRRMO': 5,
            'CPS': 6,
            'PSO': 6,
        }

        complaint_records = []
        for r in rows:
            agency = r.get('agency_code', '').strip().upper()
            off_id = agency_office_map.get(agency, 7)
            
            raw_status = (r.get('status') or '').strip().lower()
            if 'open' in raw_status or 'submit' in raw_status:
                st = 'submitted'
                st_id = 1
            elif 'progress' in raw_status:
                st = 'in_progress'
                st_id = 2
            elif 'close' in raw_status or 'resolve' in raw_status:
                st = 'resolved'
                st_id = 3
            else:
                st = 'submitted'
                st_id = 1
                
            raw_created = r.get('created_date', '').strip()
            dt_created = None
            if raw_created:
                for fmt in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%d %H:%M', '%Y-%m-%d'):
                    try:
                        dt_created = datetime.strptime(raw_created, fmt)
                        break
                    except ValueError:
                        pass
            if not dt_created:
                dt_created = datetime.now()

            raw_closed = r.get('closed_date', '').strip()
            dt_closed = None
            if raw_closed:
                for fmt in ('%Y-%m-%d %H:%M:%S', '%Y-%m-%d %H:%M', '%Y-%m-%d'):
                    try:
                        dt_closed = datetime.strptime(raw_closed, fmt)
                        break
                    except ValueError:
                        pass

            desc_parts = [r.get('descriptor', '')]
            addr = r.get('incident_address', '')
            brgy = r.get('barangay', '')
            purok = r.get('purok', '')
            if addr or brgy or purok:
                loc_desc = f"\n[Location: {addr}"
                if purok: loc_desc += f", {purok}"
                if brgy: loc_desc += f", Brgy. {brgy}"
                loc_desc += f", Cabadbaran City]"
                desc_parts.append(loc_desc)
            if r.get('channel'):
                desc_parts.append(f"\n[Reported via: {r.get('channel')}]")
            
            full_description = " ".join([p for p in desc_parts if p]).strip()

            complaint_records.append({
                'user_id': default_user_id,
                'office_id': off_id,
                'category_id': 17, # Other
                'location_id': 1,
                'risk_level_id': 2,
                'status_id': st_id,
                'title': r.get('complaint_type', 'General Complaint')[:190],
                'description': full_description,
                'attachment': None,
                'date_submitted': dt_created,
                'date_resolved': dt_closed,
                'co_office_ids': '',
                'response_message': r.get('resolution_description', '') or '',
                'sentiment': 'neutral',
                'confidence': 0.85,
                'status': st,
                'priority': 'medium'
            })

        insert_comp_sql = """
            INSERT INTO complaints_tbl (
                user_id, office_id, category_id, location_id, risk_level_id, status_id,
                title, description, attachment, date_submitted, date_resolved,
                co_office_ids, response_message, sentiment, confidence, status, priority
            ) VALUES (
                %(user_id)s, %(office_id)s, %(category_id)s, %(location_id)s, %(risk_level_id)s, %(status_id)s,
                %(title)s, %(description)s, %(attachment)s, %(date_submitted)s, %(date_resolved)s,
                %(co_office_ids)s, %(response_message)s, %(sentiment)s, %(confidence)s, %(status)s, %(priority)s
            );
        """
        cur.executemany(insert_comp_sql, complaint_records)
        pg_conn.commit()
        print(f"✅ Successfully inserted {len(complaint_records)} rows into PostgreSQL complaints_tbl!")

        cur.execute("SELECT count(*) FROM complaints_tbl;")
        count_comp = cur.fetchone()[0]
        cur.execute("SELECT count(*) FROM nyc_311_complaints;")
        count_nyc = cur.fetchone()[0]
        print(f"PostgreSQL Verification: nyc_311_complaints={count_nyc}, complaints_tbl={count_comp}")

except Exception as e:
    print(f"PostgreSQL error: {e}")
    sys.exit(1)
finally:
    if 'pg_conn' in locals() and pg_conn:
        pg_conn.close()

# 2. Update SQLite databases (for offline / Render compatibility)
for db_path in ['citizensense.db', 'BACKEND/citizensense.db']:
    if os.path.exists(db_path):
        print(f"\n--- Syncing SQLite: {db_path} ---")
        s_conn = sqlite3.connect(db_path)
        with s_conn:
            s_cur = s_conn.cursor()
            # Check if nyc_311_complaints exists in sqlite
            s_cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='nyc_311_complaints';")
            if s_cur.fetchone():
                s_cur.execute("DELETE FROM nyc_311_complaints;")
            else:
                s_cur.execute("""
                    CREATE TABLE nyc_311_complaints (
                        unique_key TEXT, created_date TEXT, closed_date TEXT, agency TEXT, agency_code TEXT,
                        agency_name TEXT, complaint_type TEXT, descriptor TEXT, location_type TEXT, incident_zip TEXT,
                        zip_code TEXT, incident_address TEXT, street_name TEXT, cross_street_1 TEXT, cross_street_2 TEXT,
                        address_type TEXT, barangay TEXT, purok TEXT, landmark TEXT, city TEXT, province TEXT,
                        status TEXT, resolution_description TEXT, resolution_action_updated_date TEXT, resolution_updated_date TEXT,
                        open_data_channel_type TEXT, channel TEXT, latitude TEXT, longitude TEXT
                    );
                """)
            
            s_insert_nyc = """
                INSERT INTO nyc_311_complaints (
                    unique_key, created_date, closed_date, agency, agency_code, agency_name,
                    complaint_type, descriptor, location_type, incident_zip, zip_code,
                    incident_address, street_name, cross_street_1, cross_street_2,
                    address_type, barangay, purok, landmark, city, province, status,
                    resolution_description, resolution_action_updated_date, resolution_updated_date,
                    open_data_channel_type, channel, latitude, longitude
                ) VALUES (
                    :unique_key, :created_date, :closed_date, :agency_code, :agency_code, :agency_name,
                    :complaint_type, :descriptor, :location_type, :zip_code, :zip_code,
                    :incident_address, :street_name, :cross_street_1, :cross_street_2,
                    :address_type, :barangay, :purok, :landmark, :city, :province, :status,
                    :resolution_description, :resolution_updated_date, :resolution_updated_date,
                    :channel, :channel, :latitude, :longitude
                );
            """
            s_cur.executemany(s_insert_nyc, rows)

            # Check if complaints_tbl exists
            s_cur.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='complaints_tbl';")
            if s_cur.fetchone():
                s_cur.execute("DELETE FROM complaints_tbl;")
                s_comp_rows = []
                for c in complaint_records:
                    rec = dict(c)
                    rec['date_submitted'] = str(c['date_submitted'])
                    rec['date_resolved'] = str(c['date_resolved']) if c['date_resolved'] else None
                    s_comp_rows.append(rec)
                
                s_cur.executemany("""
                    INSERT INTO complaints_tbl (
                        user_id, office_id, category_id, location_id, risk_level_id, status_id,
                        title, description, attachment, date_submitted, date_resolved,
                        co_office_ids, response_message, sentiment, confidence, status, priority
                    ) VALUES (
                        :user_id, :office_id, :category_id, :location_id, :risk_level_id, :status_id,
                        :title, :description, :attachment, :date_submitted, :date_resolved,
                        :co_office_ids, :response_message, :sentiment, :confidence, :status, :priority
                    );
                """, s_comp_rows)
            
            s_conn.commit()
            s_cur.execute("SELECT count(*) FROM nyc_311_complaints;")
            print(f"SQLite {db_path} nyc_311_complaints count: {s_cur.fetchone()[0]}")
            s_cur.execute("SELECT count(*) FROM complaints_tbl;")
            print(f"SQLite {db_path} complaints_tbl count: {s_cur.fetchone()[0]}")
        s_conn.close()

print("\n🎉 ALL IMPORT AND SYNC TASKS COMPLETED SUCCESSFULLY!")
