"""
Azure Functions (Python, modelo v2) con Blob Trigger.

Contiene DOS funciones independientes:

1) CargarLogCommit: se dispara cuando commit_and_upload.bat sube un .txt
   al contenedor 'test-db'. Corre el BULK INSERT puntual para ese archivo.

2) LimpiarRollback: se dispara cuando rollback.bat sube un archivo al
   contenedor 'git-rollbacks' con una lista de hashes de commit (uno por
   linea) - borra de la base de datos todo lo asociado a esos hashes, y
   de paso limpia los blobs correspondientes en 'test-db'.

Ninguna de las dos recrea la credencial ni el external data source (eso
ya quedo hecho una sola vez con setup_credencial_una_vez.sql).

Requiere:
  - Application Setting "SQL_CONNECTION_STRING" con la cadena de conexion
    a la base de datos (o, mejor, una referencia a Key Vault).
  - Driver ODBC para SQL Server disponible en el entorno de la Function.
    En un plan de Consumo Linux esto puede requerir una imagen custom;
    si te complica el despliegue, pymssql es una alternativa a pyodbc
    que no depende del driver ODBC del sistema operativo.
  - Paquete azure-storage-blob (para que LimpiarRollback pueda borrar
    tambien los blobs asociados en 'test-db').
"""

import logging
import os
import re

import azure.functions as func
import pyodbc

app = func.FunctionApp()

# Solo procesamos archivos que sigan el patron que genera commit_and_upload.bat
# (nombre_hashcorto.txt), para no ejecutar BULK INSERT con nombres arbitrarios.
BLOB_NAME_PATTERN = re.compile(r"^[A-Za-z0-9_\-]+\.txt$")


@app.function_name(name="CargarLogCommit")
@app.blob_trigger(
    arg_name="myblob",
    path="test-db/{name}",          # ajusta el contenedor si no se llama 'test-db'
    connection="AzureWebJobsStorage",  # nombre del Application Setting de storage
)
def cargar_log_commit(myblob: func.InputStream) -> None:
    blob_name = os.path.basename(myblob.name)
    logging.info("Blob detectado: %s (%s bytes)", blob_name, myblob.length)

    if not BLOB_NAME_PATTERN.match(blob_name):
        logging.warning("Nombre de blob inesperado, se omite: %s", blob_name)
        return

    conn_str = os.environ["SQL_CONNECTION_STRING"]

    # BULK INSERT no admite el FROM como parametro (?) en T-SQL, por eso se
    # arma el statement por concatenacion - es seguro porque blob_name ya
    # paso el regex de arriba (solo letras, numeros, guiones y ".txt").
    # FIELDQUOTE explicito porque Add-CommitColumn.ps1 envuelve cada campo
    # en comillas dobles (asi una coma dentro del texto original, por
    # ejemplo en la columna Message, no desalinea las columnas).
    query = f"""
        BULK INSERT dbo.BTS_MOV
        FROM '{blob_name}'
        WITH (
            DATA_SOURCE = 'MyAzureBlobStorage',
            FORMAT = 'CSV',
            FIELDQUOTE = '"',
            FIRSTROW = 2,
            FIELDTERMINATOR = ',',
            ROWTERMINATOR = '\\n'
        );
    """

    try:
        with pyodbc.connect(conn_str, autocommit=True) as conn:
            with conn.cursor() as cursor:
                cursor.execute(query)
        logging.info("Carga completada para %s", blob_name)
    except Exception:
        logging.exception("Fallo el BULK INSERT para %s", blob_name)
        raise


# Un hash de git (SHA-1) completo son 40 caracteres hexadecimales. Se valida
# estricto porque estos hashes se concatenan directo en el DELETE.
COMMIT_HASH_PATTERN = re.compile(r"^[0-9a-fA-F]{40}$")


@app.function_name(name="LimpiarRollback")
@app.blob_trigger(
    arg_name="myblob",
    path="git-rollbacks/{name}",        # contenedor separado del de los logs
    connection="AzureWebJobsStorage",
)
def limpiar_rollback(myblob: func.InputStream) -> None:
    blob_name = os.path.basename(myblob.name)
    contenido = myblob.read().decode("utf-8", errors="ignore")

    hashes = [linea.strip() for linea in contenido.splitlines() if linea.strip()]
    hashes_validos = [h for h in hashes if COMMIT_HASH_PATTERN.match(h)]

    if not hashes_validos:
        logging.warning(
            "Archivo de rollback sin hashes validos, se omite: %s", blob_name
        )
        return

    logging.info(
        "Rollback detectado (%s): %d hash(es) a limpiar", blob_name, len(hashes_validos)
    )

    conn_str = os.environ["SQL_CONNECTION_STRING"]
    # Seguro porque cada elemento ya paso el regex de 40 hex chars arriba.
    lista_hashes = ", ".join(f"'{h}'" for h in hashes_validos)
    delete_query = f"DELETE FROM dbo.BTS_MOV WHERE commit_git IN ({lista_hashes});"

    try:
        with pyodbc.connect(conn_str, autocommit=True) as conn:
            with conn.cursor() as cursor:
                cursor.execute(delete_query)
                logging.info(
                    "Filas eliminadas en dbo.BTS_MOV para %d commit(s)",
                    len(hashes_validos),
                )
    except Exception:
        logging.exception("Fallo el DELETE para el rollback %s", blob_name)
        raise

    # Limpieza opcional de los blobs .txt que se subieron bajo esos commits
    # (commit_and_upload.bat los nombra como algo_<hash_corto_8>.txt).
    try:
        from azure.storage.blob import BlobServiceClient

        blob_conn_str = os.environ["AzureWebJobsStorage"]
        service = BlobServiceClient.from_connection_string(blob_conn_str)
        contenedor_logs = service.get_container_client("test-db")

        hashes_cortos = {h[:8] for h in hashes_validos}
        for blob in contenedor_logs.list_blobs():
            if any(blob.name.endswith(f"_{hc}.txt") for hc in hashes_cortos):
                contenedor_logs.delete_blob(blob.name)
                logging.info("Blob de log eliminado: %s", blob.name)
    except Exception:
        # No bloqueante: si esto falla, el DELETE en SQL ya se hizo, solo
        # quedarian blobs viejos huerfanos en test-db para limpiar despues.
        logging.exception(
            "No se pudieron limpiar los blobs asociados al rollback (no bloqueante)"
        )